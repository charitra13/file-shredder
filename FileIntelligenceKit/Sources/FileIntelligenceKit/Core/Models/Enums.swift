import Foundation
import GRDB

/// The kind of filesystem item a record describes.
public enum ItemKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case regular
    case directory
    case symlink
    /// A directory that macOS presents as a single item (applications, bundles, libraries).
    case package
    /// Sockets, FIFOs and other special files. Recorded, never opened.
    case other

    public var displayName: String {
        switch self {
        case .regular: return "File"
        case .directory: return "Folder"
        case .symlink: return "Symbolic Link"
        case .package: return "Package"
        case .other: return "Special File"
        }
    }
}

/// Whether an indexed item could be observed the last time its location was scanned.
public enum Availability: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Observed by the most recent scan that covered it.
    case available
    /// Its path no longer exists on a reachable volume.
    case missing
    /// Its indexed location (folder or volume) is unreachable. The file may still exist.
    case unavailable
    /// The item or one of its parent folders can no longer be read.
    case inaccessible

    public var displayName: String {
        switch self {
        case .available: return "Available"
        case .missing: return "Missing"
        case .unavailable: return "Location Unavailable"
        case .inaccessible: return "Not Readable"
        }
    }
}

public enum ExtractionStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case notAttempted
    case queued
    case processing
    case completed
    case unsupported
    case failed
    case skippedByPolicy

    public var displayName: String {
        switch self {
        case .notAttempted: return "Not Attempted"
        case .queued: return "Queued"
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .unsupported: return "Unsupported Format"
        case .failed: return "Failed"
        case .skippedByPolicy: return "Skipped by Policy"
        }
    }
}

public enum ContentIndexStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case notIndexed
    case indexed
    case stale
}

/// The user's review decision for a file. Only the user sets anything other than `unreviewed`.
public enum ReviewStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case unreviewed
    case keep
    case ignored
    case reviewLater
    case archived
    case trashed

    public var displayName: String {
        switch self {
        case .unreviewed: return "Not Reviewed"
        case .keep: return "Keep"
        case .ignored: return "Suggestion Ignored"
        case .reviewLater: return "Review Later"
        case .archived: return "Archived"
        case .trashed: return "Moved to Trash"
        }
    }

    /// Decisions that suppress ordinary cleanup recommendations.
    public var suppressesRecommendations: Bool {
        switch self {
        case .keep, .ignored, .archived, .trashed: return true
        case .unreviewed, .reviewLater: return false
        }
    }
}

public enum ClassificationSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case none
    case builtInRule
    case userRule
    case learnedRule
    case user

    public var displayName: String {
        switch self {
        case .none: return "Not Classified"
        case .builtInRule: return "Built-in Rule"
        case .userRule: return "Your Rule"
        case .learnedRule: return "Learned From Your Corrections"
        case .user: return "Set by You"
        }
    }
}

public enum RootType: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case folder
    case externalVolume
    case networkVolume

    public var displayName: String {
        switch self {
        case .folder: return "Folder"
        case .externalVolume: return "External Drive"
        case .networkVolume: return "Network Volume"
        }
    }
}

public enum RootScanState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case idle
    case scanning
    case interrupted
    case failed
    case unavailable
}

public enum ScanRunState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case running
    case completed
    case cancelled
    case failed
    case interrupted

    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }
}

public enum ScanKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Recursive scan of an entire indexed location.
    case full
    /// Recursive scan of one folder inside a location.
    case subtree
    /// Non-recursive scan of one folder, usually triggered by a filesystem event.
    case shallow

    public var displayName: String {
        switch self {
        case .full: return "Full Scan"
        case .subtree: return "Folder Rescan"
        case .shallow: return "Change Update"
        }
    }
}

public enum FileActionType: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case keep
    case ignore
    case reviewLater
    case reopen
    case reclassify
    case resetClassification
    case setPreferredCopy
    case addTag
    case removeTag
    case trash
    case archive

    public var displayName: String {
        switch self {
        case .keep: return "Marked Keep"
        case .ignore: return "Ignored Suggestion"
        case .reviewLater: return "Review Later"
        case .reopen: return "Reopened"
        case .reclassify: return "Reclassified"
        case .resetClassification: return "Reset Classification"
        case .setPreferredCopy: return "Chose Preferred Copy"
        case .addTag: return "Added Tag"
        case .removeTag: return "Removed Tag"
        case .trash: return "Moved to Trash"
        case .archive: return "Archived"
        }
    }
}

public enum ActionResult: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case succeeded
    case failed
    case skipped
}

public enum CategoryKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case technical
    case semantic
    case user
}

public enum RuleMatchKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case fileExtension
    case filenameContains
    case pathPrefix

    public var displayName: String {
        switch self {
        case .fileExtension: return "Extension is"
        case .filenameContains: return "Name contains"
        case .pathPrefix: return "Path starts with"
        }
    }
}

public enum RuleOrigin: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case manual
    case learned
}

public enum RelationshipKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// An archive next to a folder with the same base name.
    case archiveExtractedFolder

    public var displayName: String {
        switch self {
        case .archiveExtractedFolder: return "Possibly extracted to"
        }
    }
}

public enum TagSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case user
    case rule
}
