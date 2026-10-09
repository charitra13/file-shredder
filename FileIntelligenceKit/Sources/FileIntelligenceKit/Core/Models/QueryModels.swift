import Foundation

public enum FileSortField: String, Sendable, CaseIterable, Hashable {
    case name
    case size
    case modified
    case created
    case category
    case priority
    case location
}

/// A structured, SQL-backed filter over the file index.
public struct FileQuery: Sendable, Equatable, Hashable {
    /// Whitespace-separated terms, each matched against the filename or folder path.
    public var text: String
    public var categoryId: Int64?
    /// When filtering by a category, also include its subcategories.
    public var includeSubcategories: Bool
    public var unclassifiedOnly: Bool
    public var rootId: Int64?
    public var itemKinds: Set<ItemKind>
    /// `nil` means any availability.
    public var availability: Set<Availability>?
    /// `nil` means any review status.
    public var reviewStatuses: Set<ReviewStatus>?
    public var fileExtensions: Set<String>?
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var duplicatesOnly: Bool
    public var minimumCleanupPriority: Int?
    public var sortField: FileSortField
    public var ascending: Bool

    public init(
        text: String = "",
        categoryId: Int64? = nil,
        includeSubcategories: Bool = true,
        unclassifiedOnly: Bool = false,
        rootId: Int64? = nil,
        itemKinds: Set<ItemKind> = [.regular, .package, .symlink, .other],
        availability: Set<Availability>? = [.available],
        reviewStatuses: Set<ReviewStatus>? = nil,
        fileExtensions: Set<String>? = nil,
        minimumSize: Int64? = nil,
        maximumSize: Int64? = nil,
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        duplicatesOnly: Bool = false,
        minimumCleanupPriority: Int? = nil,
        sortField: FileSortField = .name,
        ascending: Bool = true
    ) {
        self.text = text
        self.categoryId = categoryId
        self.includeSubcategories = includeSubcategories
        self.unclassifiedOnly = unclassifiedOnly
        self.rootId = rootId
        self.itemKinds = itemKinds
        self.availability = availability
        self.reviewStatuses = reviewStatuses
        self.fileExtensions = fileExtensions
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.duplicatesOnly = duplicatesOnly
        self.minimumCleanupPriority = minimumCleanupPriority
        self.sortField = sortField
        self.ascending = ascending
    }
}

/// A row in file lists. Sort-key properties are non-optional so they can drive table sorting.
public struct FileListItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let filename: String
    public let path: String
    public let parentPath: String
    public let fileExtension: String?
    public let itemKind: ItemKind
    public let uti: String?
    public let sizeBytes: Int64
    public let modifiedAt: Date?
    public let createdAt: Date?
    public let categoryId: Int64?
    public let categoryName: String
    public let reviewStatus: ReviewStatus
    public let availability: Availability
    public let cleanupPriority: Int?
    public let topReason: String?
    public let isDuplicate: Bool
    public let rootName: String

    public var modifiedSortKey: Date { modifiedAt ?? .distantPast }
    public var prioritySortKey: Int { cleanupPriority ?? -1 }
    public var reasonSortKey: String { topReason ?? "" }

    public init(
        id: Int64, filename: String, path: String, parentPath: String, fileExtension: String?,
        itemKind: ItemKind, uti: String?, sizeBytes: Int64, modifiedAt: Date?, createdAt: Date?,
        categoryId: Int64?, categoryName: String, reviewStatus: ReviewStatus, availability: Availability,
        cleanupPriority: Int?, topReason: String?, isDuplicate: Bool, rootName: String
    ) {
        self.id = id
        self.filename = filename
        self.path = path
        self.parentPath = parentPath
        self.fileExtension = fileExtension
        self.itemKind = itemKind
        self.uti = uti
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.reviewStatus = reviewStatus
        self.availability = availability
        self.cleanupPriority = cleanupPriority
        self.topReason = topReason
        self.isDuplicate = isDuplicate
        self.rootName = rootName
    }
}

public struct QuerySummary: Sendable, Equatable {
    public var count: Int
    public var totalBytes: Int64

    public init(count: Int, totalBytes: Int64) {
        self.count = count
        self.totalBytes = totalBytes
    }
}

public struct RelatedFile: Sendable, Identifiable, Hashable {
    public var id: Int64 { relationshipId }
    public let relationshipId: Int64
    public let kind: RelationshipKind
    public let isVerified: Bool
    public let confidence: Double
    public let evidence: String
    public let otherFileId: Int64
    public let otherPath: String
}

public struct FileDetail: Sendable {
    public let file: FileRecord
    public let category: FileCategory?
    public let root: ScanRoot?
    public let tags: [FileTag]
    public let metadata: FileMetadataRecord?
    public let duplicateGroup: DuplicateGroup?
    /// Other available copies with identical content.
    public let duplicateCopies: [FileListItem]
    public let relationships: [RelatedFile]
    public let actions: [FileActionRecord]
}

public struct OverviewStats: Sendable, Equatable {
    public var totalItems: Int
    public var totalFolders: Int
    public var totalBytes: Int64
    public var locationCount: Int
    public var enabledLocationCount: Int
    public var unavailableLocationCount: Int
    public var classifiedItems: Int
    public var unclassifiedItems: Int
    public var duplicateGroups: Int
    public var duplicateFiles: Int
    public var reclaimableBytes: Int64
    public var reviewCandidates: Int
    public var reviewCandidateBytes: Int64
    public var missingItems: Int
    public var unavailableItems: Int
    public var pendingProcessing: Int
}

public struct CategoryStat: Sendable, Identifiable, Hashable {
    public var id: Int64 { category.id ?? -1 }
    public let category: FileCategory
    public let fileCount: Int
    public let totalBytes: Int64
}

public struct DuplicateGroupSummary: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let contentHash: String
    public let sizeBytes: Int64
    public let fileCount: Int
    public let reclaimableBytes: Int64
    public let referenceFileId: Int64?
    public let referenceFilename: String
    public let referencePath: String
    public let preferredFileId: Int64?
}

public struct DuplicateOverview: Sendable, Equatable {
    public let groupCount: Int
    public let fileCount: Int
    public let reclaimableBytes: Int64
}

public struct ScanRunSummary: Sendable, Identifiable, Hashable {
    public var id: Int64 { run.id ?? -1 }
    public let run: ScanRun
    public let rootName: String

    public var duration: TimeInterval? {
        run.finishedAt.map { $0.timeIntervalSince(run.startedAt) }
    }
}

public struct RootSummary: Sendable, Identifiable, Hashable {
    public var id: Int64 { root.id ?? -1 }
    public let root: ScanRoot
    public let itemCount: Int
    public let totalBytes: Int64
    public let missingCount: Int
    public let unavailableCount: Int
    public let nestedInside: String?
}

public struct CategoryRuleSummary: Sendable, Identifiable, Hashable {
    public var id: Int64 { rule.id ?? -1 }
    public let rule: CategoryRule
    public let categoryName: String
}

public struct ActionLogEntry: Sendable, Identifiable, Hashable {
    public var id: Int64 { action.id ?? -1 }
    public let action: FileActionRecord
}
