import Foundation
import GRDB

public struct FileCategory: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "categories"

    public var id: Int64?
    public var slug: String
    public var name: String
    public var parentId: Int64?
    public var description: String?
    public var kind: CategoryKind
    public var isSystem: Bool
    public var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case name
        case parentId = "parent_id"
        case description
        case kind
        case isSystem = "is_system"
        case sortOrder = "sort_order"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct FileTag: Codable, Sendable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "file_tags"

    public var fileId: Int64
    public var tag: String
    public var source: TagSource
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case tag
        case source
        case createdAt = "created_at"
    }
}

/// Format-specific metadata gathered after the initial scan.
public struct FileMetadataRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "file_metadata"

    public var fileId: Int64
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var durationSeconds: Double?
    public var pageCount: Int?
    public var videoCodec: String?
    public var sourceLanguage: String?
    public var extractedAt: Date
    public var extractionError: String?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case durationSeconds = "duration_seconds"
        case pageCount = "page_count"
        case videoCodec = "video_codec"
        case sourceLanguage = "source_language"
        case extractedAt = "extracted_at"
        case extractionError = "extraction_error"
    }
}

/// Extracted document text. Stored apart from `files` so the main table stays small.
public struct ExtractedContent: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "extracted_content"

    public var fileId: Int64
    public var text: String
    public var characterCount: Int
    public var isTruncated: Bool
    public var extractor: String
    public var extractedAt: Date

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case text
        case characterCount = "character_count"
        case isTruncated = "is_truncated"
        case extractor
        case extractedAt = "extracted_at"
    }
}

public struct ScanRun: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "scan_runs"

    public var id: Int64?
    public var rootId: Int64
    public var kind: ScanKind
    public var scopePath: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var state: ScanRunState
    public var itemsSeen: Int
    public var directoriesVisited: Int
    public var filesAdded: Int
    public var filesUpdated: Int
    public var filesMoved: Int
    public var filesMissing: Int
    public var filesInaccessible: Int
    public var filesRemovedFromIndex: Int
    public var issuesCount: Int
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case rootId = "root_id"
        case kind
        case scopePath = "scope_path"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case state
        case itemsSeen = "items_seen"
        case directoriesVisited = "directories_visited"
        case filesAdded = "files_added"
        case filesUpdated = "files_updated"
        case filesMoved = "files_moved"
        case filesMissing = "files_missing"
        case filesInaccessible = "files_inaccessible"
        case filesRemovedFromIndex = "files_removed_from_index"
        case issuesCount = "issues_count"
        case lastError = "last_error"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ScanIssue: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "scan_issues"

    public var id: Int64?
    public var scanRunId: Int64
    public var path: String
    public var message: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case scanRunId = "scan_run_id"
        case path
        case message
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A set of available files with verified identical content (same SHA-256).
public struct DuplicateGroup: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "duplicate_groups"

    public var id: Int64?
    public var contentHash: String
    public var sizeBytes: Int64
    public var fileCount: Int
    /// Number of distinct storage items. Hard links share storage, so they count once.
    public var distinctItemCount: Int
    /// Storage recoverable by keeping one copy, without double counting hard links.
    public var reclaimableBytes: Int64
    /// The copy the user chose to keep, if any.
    public var preferredFileId: Int64?
    /// The copy treated as the reference: the preferred copy, else a kept copy, else the oldest.
    public var referenceFileId: Int64?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case contentHash = "content_hash"
        case sizeBytes = "size_bytes"
        case fileCount = "file_count"
        case distinctItemCount = "distinct_item_count"
        case reclaimableBytes = "reclaimable_bytes"
        case preferredFileId = "preferred_file_id"
        case referenceFileId = "reference_file_id"
        case updatedAt = "updated_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A user-authorised operation or decision, recorded for transparency and recovery.
public struct FileActionRecord: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "file_actions"

    public var id: Int64?
    public var fileId: Int64?
    public var batchId: String?
    public var actionType: FileActionType
    public var originalPath: String
    public var destinationPath: String?
    public var detail: String?
    public var performedAt: Date
    public var result: ActionResult
    public var errorDetails: String?
    public var recoveryInfo: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileId = "file_id"
        case batchId = "batch_id"
        case actionType = "action_type"
        case originalPath = "original_path"
        case destinationPath = "destination_path"
        case detail
        case performedAt = "performed_at"
        case result
        case errorDetails = "error_details"
        case recoveryInfo = "recovery_info"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A transparent classification rule written by the user or learned from repeated corrections.
public struct CategoryRule: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "category_rules"

    public var id: Int64?
    public var matchKind: RuleMatchKind
    public var pattern: String
    public var categoryId: Int64
    public var priority: Int
    public var isEnabled: Bool
    public var origin: RuleOrigin
    public var note: String?
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case matchKind = "match_kind"
        case pattern
        case categoryId = "category_id"
        case priority
        case isEnabled = "is_enabled"
        case origin
        case note
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct FileRelationship: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "file_relationships"

    public var id: Int64?
    public var sourceFileId: Int64
    public var targetFileId: Int64
    public var kind: RelationshipKind
    /// Verified relationships are established facts; unverified ones are heuristic inferences.
    public var isVerified: Bool
    public var confidence: Double
    public var evidence: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sourceFileId = "source_file_id"
        case targetFileId = "target_file_id"
        case kind
        case isVerified = "is_verified"
        case confidence
        case evidence
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct PreferenceRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "user_preferences"

    var key: String
    var value: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case key
        case value
        case updatedAt = "updated_at"
    }
}
