import Foundation
import GRDB

/// Per-location rules that decide which items a scan records and descends into.
public struct ExclusionConfig: Codable, Sendable, Equatable, Hashable {
    /// Folder names that are skipped entirely (not recorded, not descended into).
    public var excludedDirectoryNames: [String]
    /// Folder names that are recorded as a single item with an estimated size, but not descended into.
    public var opaqueDirectoryNames: [String]
    /// File names that are never recorded.
    public var excludedFileNames: [String]
    public var includeHiddenFiles: Bool
    /// When false (the default), packages such as `.app` bundles are recorded as one item.
    public var descendIntoPackages: Bool

    public init(
        excludedDirectoryNames: [String],
        opaqueDirectoryNames: [String],
        excludedFileNames: [String],
        includeHiddenFiles: Bool,
        descendIntoPackages: Bool
    ) {
        self.excludedDirectoryNames = excludedDirectoryNames
        self.opaqueDirectoryNames = opaqueDirectoryNames
        self.excludedFileNames = excludedFileNames
        self.includeHiddenFiles = includeHiddenFiles
        self.descendIntoPackages = descendIntoPackages
    }

    public static let `default` = ExclusionConfig(
        excludedDirectoryNames: [
            ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd",
            ".DocumentRevisions-V100", ".TemporaryItems",
        ],
        opaqueDirectoryNames: [".git", ".svn", ".hg"],
        excludedFileNames: [".DS_Store", ".localized"],
        includeHiddenFiles: true,
        descendIntoPackages: false
    )
}

/// A user-approved location that the application indexes.
public struct ScanRoot: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "scan_roots"

    public var id: Int64?
    public var displayName: String
    /// Canonical path at the time the location was last resolved.
    public var path: String
    /// Security-scoped bookmark granting sandboxed access. `nil` when bookmarks are not in use.
    public var bookmark: Data?
    public var rootType: RootType
    public var volumeUUID: String?
    public var isEnabled: Bool
    public var scanState: RootScanState
    public var lastSuccessfulScanAt: Date?
    public var lastScanStartedAt: Date?
    public var exclusions: ExclusionConfig
    public var lastError: String?
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case path
        case bookmark
        case rootType = "root_type"
        case volumeUUID = "volume_uuid"
        case isEnabled = "is_enabled"
        case scanState = "scan_state"
        case lastSuccessfulScanAt = "last_successful_scan_at"
        case lastScanStartedAt = "last_scan_started_at"
        case exclusions
        case lastError = "last_error"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
