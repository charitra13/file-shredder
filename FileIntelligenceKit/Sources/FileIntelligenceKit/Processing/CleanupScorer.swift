import Foundation
import GRDB

/// Duplicate facts relevant to one file's score.
public struct DuplicateContext: Sendable, Equatable {
    public var isReferenceCopy: Bool
    public var copyCount: Int
    public var referencePath: String?
    public var referenceInSameFolder: Bool

    public init(isReferenceCopy: Bool, copyCount: Int, referencePath: String?, referenceInSameFolder: Bool) {
        self.isReferenceCopy = isReferenceCopy
        self.copyCount = copyCount
        self.referencePath = referencePath
        self.referenceInSameFolder = referenceInSameFolder
    }
}

public struct ScoringInput: Sendable, Equatable {
    public var filename: String
    public var itemKind: ItemKind
    public var availability: Availability
    public var reviewStatus: ReviewStatus
    public var categorySlug: String?
    public var sizeBytes: Int64
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var firstIndexedAt: Date
    public var duplicate: DuplicateContext?
    public var isInsideProject: Bool
    public var hasSiblingFolderWithSameName: Bool

    public init(
        filename: String, itemKind: ItemKind, availability: Availability, reviewStatus: ReviewStatus,
        categorySlug: String?, sizeBytes: Int64, createdAt: Date?, modifiedAt: Date?, firstIndexedAt: Date,
        duplicate: DuplicateContext? = nil, isInsideProject: Bool = false, hasSiblingFolderWithSameName: Bool = false
    ) {
        self.filename = filename
        self.itemKind = itemKind
        self.availability = availability
        self.reviewStatus = reviewStatus
        self.categorySlug = categorySlug
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.firstIndexedAt = firstIndexedAt
        self.duplicate = duplicate
        self.isInsideProject = isInsideProject
        self.hasSiblingFolderWithSameName = hasSiblingFolderWithSameName
    }
}

public struct ScoringOutcome: Sendable, Equatable {
    /// `nil` when the item is not eligible for scoring (folders, links, unavailable files).
    public var priority: Int?
    /// Sorted by weight, strongest first. Empty when nothing suggests a review.
    public var reasons: [CleanupReason]
}

/// Explainable review-priority heuristic.
///
/// The score orders files for human review. It is never a probability that removal is safe, it never
/// triggers an operation, and an explicit Keep or Ignore decision always suppresses it.
public struct CleanupScorer: Sendable {
    let database: AppDatabase
    var pageSize = 1_000

    public init(database: AppDatabase) {
        self.database = database
    }

    static let projectMarkers = [
        ".git", "package.json", "Package.swift", "Cargo.toml", "go.mod", "pyproject.toml",
        "pom.xml", "build.gradle", "build.gradle.kts", "Gemfile", "composer.json", "CMakeLists.txt",
    ]

    // MARK: - Pure evaluation

    public static func evaluate(_ input: ScoringInput, settings: CleanupScoringSettings, now: Date) -> ScoringOutcome {
        guard input.availability == .available, input.itemKind == .regular || input.itemKind == .package else {
            return ScoringOutcome(priority: nil, reasons: [])
        }
        if input.reviewStatus.suppressesRecommendations {
            return ScoringOutcome(priority: 0, reasons: [])
        }

        let weights = settings.weights
        let size = ByteCountFormatter.string(fromByteCount: input.sizeBytes, countStyle: .file)
        var reasons: [CleanupReason] = []
        func add(_ code: String, _ weight: Int, _ message: String) {
            guard weight != 0 else { return }
            reasons.append(CleanupReason(code: code, message: message, weight: weight))
        }

        if let duplicate = input.duplicate, !duplicate.isReferenceCopy {
            let location = duplicate.referenceInSameFolder ? "in the same folder" : "in another indexed location"
            add("exactDuplicate", weights.exactDuplicate,
                "An identical copy exists \(location) (\(duplicate.copyCount) copies in total).")
        }

        switch input.categorySlug ?? "unknown" {
        case "temporary":
            add("temporaryFile", weights.temporaryFile, "This looks like a temporary or partially downloaded file.")
        case "installers":
            let added = input.createdAt ?? input.modifiedAt ?? input.firstIndexedAt
            let days = DateUtilities.wholeDays(from: added, to: now)
            if days >= settings.installerAgeDays {
                add("oldInstaller", weights.oldInstaller,
                    "This installer was added \(days) days ago and has not been reviewed.")
            }
        case "archives":
            if input.sizeBytes >= settings.largeArchiveThreshold {
                add("largeArchive", weights.largeArchive, "This archive occupies \(size).")
            }
            if input.hasSiblingFolderWithSameName {
                add("archiveAlreadyExtracted", weights.archiveAlreadyExtracted,
                    "A folder with the same name is next to this archive, so it may already have been extracted.")
            }
        case "unknown":
            add("unclassified", weights.unclassified, "This item has not been classified.")
        default:
            break
        }

        if input.sizeBytes >= settings.veryLargeFileThreshold {
            add("veryLargeFile", weights.veryLargeFile, "This file is very large (\(size)).")
        } else if input.sizeBytes >= settings.largeFileThreshold {
            add("largeFile", weights.largeFile, "This file is large (\(size)).")
        }

        if let modified = input.modifiedAt {
            let days = DateUtilities.wholeDays(from: modified, to: now)
            if days >= settings.staleAgeDays {
                add("notModifiedRecently", weights.notModifiedRecently,
                    "Not modified for \(days) days. This alone does not mean it is unused.")
            }
        }

        guard reasons.contains(where: { $0.weight > 0 }) else {
            return ScoringOutcome(priority: 0, reasons: [])
        }

        if input.isInsideProject {
            add("projectMember", -weights.projectMemberPenalty,
                "It is inside a project folder and may be needed by that project.")
        }
        if ["source-code", "configuration", "databases"].contains(input.categorySlug ?? "") {
            add("sourceOrConfiguration", -weights.sourceOrConfigPenalty,
                "Source, configuration and database files are often needed by other software.")
        }

        let total = reasons.reduce(0) { $0 + $1.weight }
        let sorted = reasons.sorted { lhs, rhs in
            lhs.weight != rhs.weight ? lhs.weight > rhs.weight : lhs.code < rhs.code
        }
        return ScoringOutcome(priority: min(100, max(0, total)), reasons: sorted)
    }

    // MARK: - Persistence

    /// Rescores every eligible file. Folders and links get no score.
    public func scoreAll(
        settings: CleanupScoringSettings,
        now: Date = Date(),
        progress: @Sendable (ProcessingProgress) -> Void = { _ in }
    ) async throws {
        let context = try loadContext()
        let total = try await database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE item_kind IN ('regular', 'package')") ?? 0
        }
        var lastId: Int64 = 0
        var processed = 0
        while true {
            try Task.checkCancellation()
            let afterId = lastId
            let page = try await database.reader.read { db in
                try Self.fetchInputs(db, context: context, condition: "f.id > ?", arguments: [afterId], limit: pageSize)
            }
            guard let last = page.last else { break }
            lastId = last.id
            try write(page.map { ($0.id, Self.evaluate($0.input, settings: settings, now: now), $0.siblingFolderId) }, now: now)
            processed += page.count
            progress(ProcessingProgress(stage: .scoring, completed: processed, total: total))
        }
    }

    /// Rescores specific files, for example right after a review decision.
    public func score(fileIds: [Int64], settings: CleanupScoringSettings, now: Date = Date()) throws {
        guard !fileIds.isEmpty else { return }
        let context = try loadContext()
        let inputs = try database.reader.read { db -> [ScoringRow] in
            var result: [ScoringRow] = []
            try SQL.forEachChunk(of: fileIds) { chunk, placeholders in
                result += try Self.fetchInputs(
                    db,
                    context: context,
                    condition: "f.id IN (\(placeholders))",
                    arguments: StatementArguments(chunk),
                    limit: chunk.count
                )
            }
            return result
        }
        try write(inputs.map { ($0.id, Self.evaluate($0.input, settings: settings, now: now), $0.siblingFolderId) }, now: now)
    }

    struct Context: Sendable {
        var duplicates: [Int64: DuplicateContext]
        var projectFolders: Set<String>
    }

    struct ScoringRow: Sendable {
        let id: Int64
        let input: ScoringInput
        let siblingFolderId: Int64?
    }

    private func loadContext() throws -> Context {
        try database.reader.read { db in
            var duplicates: [Int64: DuplicateContext] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.id, f.parent_path, g.reference_file_id, g.file_count, r.path AS reference_path, r.parent_path AS reference_parent
                FROM files f
                JOIN duplicate_groups g ON g.content_hash = f.content_hash
                LEFT JOIN files r ON r.id = g.reference_file_id
                WHERE f.availability = 'available' AND f.item_kind = 'regular'
                """)
            for row in rows {
                let id: Int64 = row["id"]
                let referenceId: Int64? = row["reference_file_id"]
                let parent: String = row["parent_path"]
                let referenceParent: String? = row["reference_parent"]
                duplicates[id] = DuplicateContext(
                    isReferenceCopy: referenceId == id,
                    copyCount: row["file_count"],
                    referencePath: row["reference_path"],
                    referenceInSameFolder: referenceParent == parent
                )
            }

            let markers = Self.projectMarkers
            let projectRows = try String.fetchAll(db, sql: """
                SELECT DISTINCT parent_path FROM files
                WHERE availability = 'available'
                  AND (filename IN (\(SQL.placeholders(markers.count))) OR file_extension IN ('xcodeproj', 'xcworkspace'))
                """, arguments: StatementArguments(markers))
            return Context(duplicates: duplicates, projectFolders: Set(projectRows))
        }
    }

    private static func fetchInputs(
        _ db: Database,
        context: Context,
        condition: String,
        arguments: StatementArguments,
        limit: Int
    ) throws -> [ScoringRow] {
        var allArguments = arguments
        allArguments += [limit]
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id, f.filename, f.parent_path, f.item_kind, f.availability, f.review_status, f.size_bytes,
                   f.created_at, f.modified_at, f.first_indexed_at, c.slug AS category_slug
            FROM files f
            LEFT JOIN categories c ON c.id = f.category_id
            WHERE f.item_kind IN ('regular', 'package') AND \(condition)
            ORDER BY f.id
            LIMIT ?
            """, arguments: allArguments)

        let sibling = try db.cachedStatement(sql: """
            SELECT id FROM files WHERE parent_path = ? AND filename = ? AND item_kind = 'directory' AND availability = 'available' LIMIT 1
            """)

        return try rows.map { row -> ScoringRow in
            let id: Int64 = row["id"]
            let filename: String = row["filename"]
            let parent: String = row["parent_path"]
            let slug: String? = row["category_slug"]
            let kindRaw: String = row["item_kind"]
            let availabilityRaw: String = row["availability"]
            let reviewRaw: String = row["review_status"]

            var siblingId: Int64?
            if slug == "archives" {
                siblingId = try Int64.fetchOne(sibling, arguments: [parent, archiveStem(filename)])
            }
            let input = ScoringInput(
                filename: filename,
                itemKind: ItemKind(rawValue: kindRaw) ?? .other,
                availability: Availability(rawValue: availabilityRaw) ?? .available,
                reviewStatus: ReviewStatus(rawValue: reviewRaw) ?? .unreviewed,
                categorySlug: slug,
                sizeBytes: row["size_bytes"],
                createdAt: row["created_at"],
                modifiedAt: row["modified_at"],
                firstIndexedAt: row["first_indexed_at"],
                duplicate: context.duplicates[id],
                isInsideProject: isInsideProject(parent: parent, projects: context.projectFolders),
                hasSiblingFolderWithSameName: siblingId != nil
            )
            return ScoringRow(id: id, input: input, siblingFolderId: siblingId)
        }
    }

    /// "photos.tar.gz" → "photos", "project.zip" → "project".
    static func archiveStem(_ filename: String) -> String {
        var stem = (filename as NSString).deletingPathExtension
        if stem.lowercased().hasSuffix(".tar") {
            stem = (stem as NSString).deletingPathExtension
        }
        return stem
    }

    static func isInsideProject(parent: String, projects: Set<String>) -> Bool {
        guard !projects.isEmpty else { return false }
        if projects.contains(parent) { return true }
        return PathUtilities.ancestors(of: parent).contains { projects.contains($0) }
    }

    private func write(_ outcomes: [(Int64, ScoringOutcome, Int64?)], now: Date) throws {
        guard !outcomes.isEmpty else { return }
        try database.writer.write { db in
            let update = try db.cachedStatement(sql: """
                UPDATE files SET cleanup_priority = ?, cleanup_reasons = ?, scored_at = ? WHERE id = ?
                """)
            let relate = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO file_relationships (source_file_id, target_file_id, kind, is_verified, confidence, evidence, created_at)
                VALUES (?, ?, ?, 0, 0.5, ?, ?)
                """)
            for (id, outcome, siblingId) in outcomes {
                let reasons = outcome.reasons.isEmpty ? nil : SQL.encodeJSON(outcome.reasons)
                try update.execute(arguments: [outcome.priority, reasons, now, id])
                if let siblingId {
                    try relate.execute(arguments: [
                        id, siblingId, RelationshipKind.archiveExtractedFolder,
                        "A folder with the archive's base name exists in the same folder.", now,
                    ])
                }
            }
        }
    }
}
