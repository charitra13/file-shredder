import Foundation
import GRDB

/// One explained contribution to a file's review priority.
public struct CleanupReason: Codable, Sendable, Equatable, Hashable {
    public var code: String
    public var message: String
    /// Positive weights raise the priority, negative weights lower it.
    public var weight: Int

    public init(code: String, message: String, weight: Int) {
        self.code = code
        self.message = message
        self.weight = weight
    }
}

/// The canonical record for an indexed filesystem item.
public struct FileRecord: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "files"

    public var id: Int64?
    /// The indexed location that currently owns this item (the deepest enabled location containing it).
    public var rootId: Int64
    public var path: String
    public var filename: String
    public var parentPath: String
    /// Lowercased filename extension without the dot.
    public var fileExtension: String?
    public var uti: String?
    public var mimeType: String?
    public var itemKind: ItemKind
    public var sizeBytes: Int64
    public var allocatedBytes: Int64?
    /// True when the size of a package or opaque folder was capped while estimating.
    public var sizeIsEstimate: Bool
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var volumeUUID: String?
    /// Filesystem inode number (bit pattern of the unsigned value).
    public var inode: Int64?
    public var isHidden: Bool
    public var symlinkTarget: String?
    public var detectedSignature: String?
    /// SHA-256 of the first and last 64 KiB plus the size, used to prune duplicate candidates.
    public var quickHash: String?
    /// Full SHA-256 of the content, hex encoded.
    public var contentHash: String?
    public var hashedAt: Date?
    public var categoryId: Int64?
    public var classificationSource: ClassificationSource
    public var classificationConfidence: Double?
    public var classificationExplanation: String?
    public var classifiedAt: Date?
    public var enrichedAt: Date?
    public var contentExtractionStatus: ExtractionStatus
    public var contentIndexStatus: ContentIndexStatus
    public var reviewStatus: ReviewStatus
    public var reviewedAt: Date?
    /// Review priority from 0 to 100. A prioritisation heuristic, not a probability that removal is safe.
    public var cleanupPriority: Int?
    public var cleanupReasons: [CleanupReason]?
    public var scoredAt: Date?
    public var firstIndexedAt: Date
    public var lastIndexedAt: Date
    public var lastSeenAt: Date
    public var lastSeenScanId: Int64?
    public var availability: Availability
    public var missingSince: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case rootId = "root_id"
        case path
        case filename
        case parentPath = "parent_path"
        case fileExtension = "file_extension"
        case uti
        case mimeType = "mime_type"
        case itemKind = "item_kind"
        case sizeBytes = "size_bytes"
        case allocatedBytes = "allocated_bytes"
        case sizeIsEstimate = "size_is_estimate"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case volumeUUID = "volume_uuid"
        case inode
        case isHidden = "is_hidden"
        case symlinkTarget = "symlink_target"
        case detectedSignature = "detected_signature"
        case quickHash = "quick_hash"
        case contentHash = "content_hash"
        case hashedAt = "hashed_at"
        case categoryId = "category_id"
        case classificationSource = "classification_source"
        case classificationConfidence = "classification_confidence"
        case classificationExplanation = "classification_explanation"
        case classifiedAt = "classified_at"
        case enrichedAt = "enriched_at"
        case contentExtractionStatus = "content_extraction_status"
        case contentIndexStatus = "content_index_status"
        case reviewStatus = "review_status"
        case reviewedAt = "reviewed_at"
        case cleanupPriority = "cleanup_priority"
        case cleanupReasons = "cleanup_reasons"
        case scoredAt = "scored_at"
        case firstIndexedAt = "first_indexed_at"
        case lastIndexedAt = "last_indexed_at"
        case lastSeenAt = "last_seen_at"
        case lastSeenScanId = "last_seen_scan_id"
        case availability
        case missingSince = "missing_since"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension FileRecord {
    /// Creates a new record for an item observed for the first time.
    init(observation: FileObservation, rootId: Int64, runId: Int64, now: Date) {
        self.init(
            id: nil,
            rootId: rootId,
            path: observation.path,
            filename: observation.filename,
            parentPath: observation.parentPath,
            fileExtension: observation.fileExtension,
            uti: observation.uti,
            mimeType: observation.mimeType,
            itemKind: observation.itemKind,
            sizeBytes: observation.sizeBytes,
            allocatedBytes: observation.allocatedBytes,
            sizeIsEstimate: observation.sizeIsEstimate,
            createdAt: observation.createdAt,
            modifiedAt: observation.modifiedAt,
            volumeUUID: observation.volumeUUID,
            inode: observation.inode,
            isHidden: observation.isHidden,
            symlinkTarget: observation.symlinkTarget,
            detectedSignature: nil,
            quickHash: nil,
            contentHash: nil,
            hashedAt: nil,
            categoryId: nil,
            classificationSource: .none,
            classificationConfidence: nil,
            classificationExplanation: nil,
            classifiedAt: nil,
            enrichedAt: nil,
            contentExtractionStatus: .notAttempted,
            contentIndexStatus: .notIndexed,
            reviewStatus: .unreviewed,
            reviewedAt: nil,
            cleanupPriority: nil,
            cleanupReasons: nil,
            scoredAt: nil,
            firstIndexedAt: now,
            lastIndexedAt: now,
            lastSeenAt: now,
            lastSeenScanId: runId,
            availability: .available,
            missingSince: nil
        )
    }

    /// True when the observation differs from the stored metadata in a way that invalidates derived data.
    func contentMayDiffer(from observation: FileObservation) -> Bool {
        itemKind != observation.itemKind
            || sizeBytes != observation.sizeBytes
            || inode != observation.inode
            || symlinkTarget != observation.symlinkTarget
            || !DateUtilities.approximatelyEqual(modifiedAt, observation.modifiedAt)
    }

    /// Copies observed metadata onto the record while keeping its identity and user decisions.
    mutating func absorb(_ observation: FileObservation, rootId: Int64, runId: Int64, now: Date, contentChanged: Bool) {
        let nameChanged = filename != observation.filename
        self.rootId = rootId
        path = observation.path
        filename = observation.filename
        parentPath = observation.parentPath
        fileExtension = observation.fileExtension
        uti = observation.uti
        mimeType = observation.mimeType
        itemKind = observation.itemKind
        sizeBytes = observation.sizeBytes
        allocatedBytes = observation.allocatedBytes
        sizeIsEstimate = observation.sizeIsEstimate
        createdAt = observation.createdAt
        modifiedAt = observation.modifiedAt
        volumeUUID = observation.volumeUUID
        inode = observation.inode
        isHidden = observation.isHidden
        symlinkTarget = observation.symlinkTarget
        lastSeenAt = now
        lastSeenScanId = runId
        lastIndexedAt = now
        availability = .available
        missingSince = nil

        if contentChanged {
            detectedSignature = nil
            quickHash = nil
            contentHash = nil
            hashedAt = nil
            enrichedAt = nil
            contentExtractionStatus = .notAttempted
            if contentIndexStatus == .indexed {
                contentIndexStatus = .stale
            }
        }
        if (contentChanged || nameChanged), classificationSource != .user {
            classifiedAt = nil
        }
        scoredAt = nil
    }
}
