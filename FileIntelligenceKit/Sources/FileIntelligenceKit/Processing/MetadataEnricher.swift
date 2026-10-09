import AVFoundation
import Foundation
import GRDB
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Format-specific metadata read without decoding full content.
public struct MediaMetadata: Sendable, Equatable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var durationSeconds: Double?
    public var pageCount: Int?
    public var videoCodec: String?

    public var isEmpty: Bool {
        pixelWidth == nil && pixelHeight == nil && durationSeconds == nil && pageCount == nil && videoCodec == nil
    }
}

/// Second-stage metadata: content signatures and media properties.
///
/// Runs after the metadata scan has persisted the index, so a slow or failing file never blocks indexing.
/// Files are read through Apple's parsers (ImageIO, AVFoundation, PDFKit); nothing is executed.
public struct MetadataEnricher: Sendable {
    let database: AppDatabase
    var maxConcurrency = 4
    var pageSize = 200
    /// Larger PDFs are not opened for a page count.
    var maximumPDFSize: Int64 = 512 * 1_024 * 1_024
    var mediaTimeout: Double = 10

    public init(database: AppDatabase) {
        self.database = database
    }

    struct Item: Sendable {
        let id: Int64
        let path: String
        let uti: String?
        let itemKind: ItemKind
        let sizeBytes: Int64
    }

    struct EnrichmentResult: Sendable {
        let id: Int64
        let signature: FormatSignature?
        let impliedUTI: String?
        let impliedMIME: String?
        let media: MediaMetadata?
        let error: String?
    }

    @discardableResult
    public func enrichPending(progress: @Sendable (ProcessingProgress) -> Void = { _ in }) async throws -> Int {
        let total = try await database.reader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM files
                WHERE enriched_at IS NULL AND availability = 'available' AND item_kind IN ('regular', 'package')
                """) ?? 0
        }
        guard total > 0 else { return 0 }

        var processed = 0
        var lastId: Int64 = 0
        while true {
            try Task.checkCancellation()
            let afterId = lastId
            let page: [Item] = try await database.reader.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, path, uti, item_kind, size_bytes FROM files
                    WHERE enriched_at IS NULL AND availability = 'available'
                      AND item_kind IN ('regular', 'package') AND id > ?
                    ORDER BY id LIMIT ?
                    """, arguments: [afterId, pageSize]).map { row -> Item in
                    let kindRaw: String = row["item_kind"]
                    return Item(
                        id: row["id"],
                        path: row["path"],
                        uti: row["uti"],
                        itemKind: ItemKind(rawValue: kindRaw) ?? .other,
                        sizeBytes: row["size_bytes"]
                    )
                }
            }
            guard let last = page.last else { break }
            lastId = last.id

            let enricher = self
            let results = try await concurrentMap(page, maxConcurrency: maxConcurrency) { item in
                await enricher.enrich(item)
            }
            try write(results, now: Date())
            processed += page.count
            progress(ProcessingProgress(stage: .metadata, completed: processed, total: total))
        }
        return processed
    }

    func enrich(_ item: Item) async -> EnrichmentResult {
        var signature: FormatSignature?
        if item.itemKind == .regular && item.sizeBytes > 0 {
            signature = FormatSignature.detect(path: item.path)
        }
        let impliedUTI = item.uti == nil ? signature?.impliedTypeIdentifier : nil
        let effectiveUTI = item.uti ?? impliedUTI
        let impliedMIME = impliedUTI.flatMap { UTType($0)?.preferredMIMEType }

        var media: MediaMetadata?
        var errorMessage: String?
        if item.itemKind == .regular, let effectiveUTI, let type = UTType(effectiveUTI) {
            let url = URL(fileURLWithPath: item.path)
            if type.conforms(to: .image) {
                media = Self.imageMetadata(url)
            } else if type.conforms(to: .audiovisualContent) {
                do {
                    media = try await withTimeout(seconds: mediaTimeout) {
                        try await Self.audiovisualMetadata(url)
                    }
                } catch {
                    errorMessage = "Media metadata unavailable: \(error.localizedDescription)"
                }
            } else if type.conforms(to: .pdf), item.sizeBytes <= maximumPDFSize {
                if let document = PDFDocument(url: url) {
                    media = MediaMetadata(pageCount: document.pageCount)
                } else {
                    errorMessage = "The PDF could not be opened."
                }
            }
        }
        if media?.isEmpty == true { media = nil }
        return EnrichmentResult(
            id: item.id,
            signature: signature,
            impliedUTI: impliedUTI,
            impliedMIME: impliedMIME,
            media: media,
            error: errorMessage
        )
    }

    static func imageMetadata(_ url: URL) -> MediaMetadata? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any] else {
            return nil
        }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        return MediaMetadata(pixelWidth: width, pixelHeight: height)
    }

    static func audiovisualMetadata(_ url: URL) async throws -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        var metadata = MediaMetadata()
        let seconds = CMTimeGetSeconds(duration)
        if seconds.isFinite && seconds > 0 {
            metadata.durationSeconds = seconds
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        if let track = tracks.first {
            let size = try await track.load(.naturalSize)
            if size.width > 0 && size.height > 0 {
                metadata.pixelWidth = Int(size.width.rounded())
                metadata.pixelHeight = Int(size.height.rounded())
            }
            let descriptions = try await track.load(.formatDescriptions)
            if let first = descriptions.first {
                metadata.videoCodec = Self.fourCharacterCode(CMFormatDescriptionGetMediaSubType(first))
            }
        }
        return metadata
    }

    static func fourCharacterCode(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func write(_ results: [EnrichmentResult], now: Date) throws {
        try database.writer.write { db in
            let update = try db.cachedStatement(sql: """
                UPDATE files
                SET detected_signature = ?, uti = COALESCE(uti, ?), mime_type = COALESCE(mime_type, ?), enriched_at = ?
                WHERE id = ?
                """)
            let upsert = try db.cachedStatement(sql: """
                INSERT INTO file_metadata (file_id, pixel_width, pixel_height, duration_seconds, page_count, video_codec, extracted_at, extraction_error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                    pixel_width = excluded.pixel_width, pixel_height = excluded.pixel_height,
                    duration_seconds = excluded.duration_seconds, page_count = excluded.page_count,
                    video_codec = excluded.video_codec, extracted_at = excluded.extracted_at,
                    extraction_error = excluded.extraction_error
                """)
            for result in results {
                try update.execute(arguments: [result.signature?.rawValue, result.impliedUTI, result.impliedMIME, now, result.id])
                if result.media != nil || result.error != nil {
                    let media = result.media ?? MediaMetadata()
                    try upsert.execute(arguments: [
                        result.id, media.pixelWidth, media.pixelHeight, media.durationSeconds,
                        media.pageCount, media.videoCodec, now, result.error,
                    ])
                }
            }
        }
    }
}
