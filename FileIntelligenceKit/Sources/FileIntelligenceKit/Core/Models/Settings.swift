import Foundation

/// Weights and thresholds for the cleanup review-priority heuristic.
///
/// The resulting 0–100 score orders files for review. It is not a probability that a file is safe to delete.
public struct CleanupScoringSettings: Codable, Sendable, Equatable, Hashable {
    public struct Weights: Codable, Sendable, Equatable, Hashable {
        public var exactDuplicate: Int
        public var temporaryFile: Int
        public var oldInstaller: Int
        public var largeFile: Int
        public var veryLargeFile: Int
        public var largeArchive: Int
        public var archiveAlreadyExtracted: Int
        public var unclassified: Int
        public var notModifiedRecently: Int
        /// Subtracted when a file sits inside a detected project folder.
        public var projectMemberPenalty: Int
        /// Subtracted for source code, configuration and database files.
        public var sourceOrConfigPenalty: Int

        public init(
            exactDuplicate: Int = 40,
            temporaryFile: Int = 35,
            oldInstaller: Int = 30,
            largeFile: Int = 15,
            veryLargeFile: Int = 25,
            largeArchive: Int = 10,
            archiveAlreadyExtracted: Int = 15,
            unclassified: Int = 10,
            notModifiedRecently: Int = 10,
            projectMemberPenalty: Int = 25,
            sourceOrConfigPenalty: Int = 15
        ) {
            self.exactDuplicate = exactDuplicate
            self.temporaryFile = temporaryFile
            self.oldInstaller = oldInstaller
            self.largeFile = largeFile
            self.veryLargeFile = veryLargeFile
            self.largeArchive = largeArchive
            self.archiveAlreadyExtracted = archiveAlreadyExtracted
            self.unclassified = unclassified
            self.notModifiedRecently = notModifiedRecently
            self.projectMemberPenalty = projectMemberPenalty
            self.sourceOrConfigPenalty = sourceOrConfigPenalty
        }
    }

    /// Files at or above this priority appear among review candidates.
    public var minimumCandidatePriority: Int
    public var largeFileThreshold: Int64
    public var veryLargeFileThreshold: Int64
    public var largeArchiveThreshold: Int64
    public var installerAgeDays: Int
    public var staleAgeDays: Int
    public var weights: Weights

    public init(
        minimumCandidatePriority: Int = 25,
        largeFileThreshold: Int64 = 500 * 1_024 * 1_024,
        veryLargeFileThreshold: Int64 = 2 * 1_024 * 1_024 * 1_024,
        largeArchiveThreshold: Int64 = 100 * 1_024 * 1_024,
        installerAgeDays: Int = 30,
        staleAgeDays: Int = 365,
        weights: Weights = Weights()
    ) {
        self.minimumCandidatePriority = minimumCandidatePriority
        self.largeFileThreshold = largeFileThreshold
        self.veryLargeFileThreshold = veryLargeFileThreshold
        self.largeArchiveThreshold = largeArchiveThreshold
        self.installerAgeDays = installerAgeDays
        self.staleAgeDays = staleAgeDays
        self.weights = weights
    }
}

public struct HashingSettings: Codable, Sendable, Equatable, Hashable {
    /// Files smaller than this are not considered for duplicate detection.
    public var minimumDuplicateSize: Int64
    /// Files at least this large get a cheap partial hash before a full hash.
    public var quickHashThreshold: Int64
    public var maxConcurrentHashes: Int

    public init(minimumDuplicateSize: Int64 = 1, quickHashThreshold: Int64 = 4 * 1_024 * 1_024, maxConcurrentHashes: Int = 2) {
        self.minimumDuplicateSize = minimumDuplicateSize
        self.quickHashThreshold = quickHashThreshold
        self.maxConcurrentHashes = maxConcurrentHashes
    }
}

/// Application-wide preferences persisted in `user_preferences`.
public struct AppSettings: Codable, Sendable, Equatable, Hashable {
    /// Exclusions applied to newly added locations.
    public var defaultExclusions: ExclusionConfig
    public var monitorFileSystemChanges: Bool
    /// Hours between automatic reconciliation scans while the app is running. Zero disables them.
    public var reconciliationIntervalHours: Int
    public var scoring: CleanupScoringSettings
    public var hashing: HashingSettings

    public init(
        defaultExclusions: ExclusionConfig = .default,
        monitorFileSystemChanges: Bool = true,
        reconciliationIntervalHours: Int = 6,
        scoring: CleanupScoringSettings = CleanupScoringSettings(),
        hashing: HashingSettings = HashingSettings()
    ) {
        self.defaultExclusions = defaultExclusions
        self.monitorFileSystemChanges = monitorFileSystemChanges
        self.reconciliationIntervalHours = reconciliationIntervalHours
        self.scoring = scoring
        self.hashing = hashing
    }

    public static let storageKey = "app.settings"
}
