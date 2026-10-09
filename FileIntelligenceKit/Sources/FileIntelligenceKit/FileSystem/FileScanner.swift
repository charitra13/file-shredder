import Foundation
import UniformTypeIdentifiers

/// Metadata for one item, gathered with `lstat` and the filename only. File contents are never read here.
public struct FileObservation: Sendable, Equatable {
    public var path: String
    public var filename: String
    public var parentPath: String
    public var fileExtension: String?
    public var itemKind: ItemKind
    public var uti: String?
    public var mimeType: String?
    public var sizeBytes: Int64
    public var allocatedBytes: Int64?
    public var sizeIsEstimate: Bool
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var volumeUUID: String?
    public var inode: Int64?
    public var isHidden: Bool
    public var symlinkTarget: String?
}

/// Which part of an indexed location a scan covers.
public struct ScanScope: Sendable, Equatable, Hashable {
    public enum Depth: String, Sendable, Equatable, Hashable {
        case recursive
        case shallow
    }

    public var rootPath: String
    public var startPath: String
    public var depth: Depth

    public init(rootPath: String, startPath: String, depth: Depth) {
        self.rootPath = rootPath
        self.startPath = startPath
        self.depth = depth
    }

    public static func full(rootPath: String) -> ScanScope {
        ScanScope(rootPath: rootPath, startPath: rootPath, depth: .recursive)
    }

    public var kind: ScanKind {
        if depth == .shallow { return .shallow }
        return startPath == rootPath ? .full : .subtree
    }
}

public struct ScanRequest: Sendable {
    public var scope: ScanScope
    public var exclusions: ExclusionConfig
    /// Folders owned by other enabled, nested locations. They are scanned by their own location.
    public var skippedSubtrees: Set<String>
    public var batchSize: Int

    public init(scope: ScanScope, exclusions: ExclusionConfig, skippedSubtrees: Set<String> = [], batchSize: Int = 500) {
        self.scope = scope
        self.exclusions = exclusions
        self.skippedSubtrees = skippedSubtrees
        self.batchSize = batchSize
    }
}

public struct ScanIssueInfo: Sendable, Equatable {
    public var path: String
    public var message: String
}

public struct ScanBatch: Sendable {
    public var observations: [FileObservation]
    public var issues: [ScanIssueInfo]
    /// Running totals for progress reporting.
    public var itemsSeen: Int
    public var directoriesVisited: Int
}

public struct ScanTraversalSummary: Sendable, Equatable {
    public var itemsSeen = 0
    public var directoriesVisited = 0
    public var issueCount = 0
    /// Folders that could not be listed. Previously indexed items beneath them are not marked missing.
    public var unreadableDirectories: [String] = []
}

/// Walks a folder tree iteratively and reports observations in batches.
///
/// Policies:
/// - Symbolic links are recorded as links and never followed, so link cycles cannot occur.
/// - Folders are tracked by device and inode, guarding against firmlinks and other aliasing.
/// - Packages and opaque folders are recorded as one item with a capped size estimate.
/// - Unreadable folders are reported as issues and do not abort the scan.
public struct FileScanner: Sendable {
    public var directorySizeEntryLimit: Int

    public init(directorySizeEntryLimit: Int = 25_000) {
        self.directorySizeEntryLimit = directorySizeEntryLimit
    }

    private struct DirectoryIdentity: Hashable {
        let device: Int32
        let inode: UInt64
    }

    public func scan(
        _ request: ScanRequest,
        onBatch: (ScanBatch) async throws -> Void
    ) async throws -> ScanTraversalSummary {
        let policy = ExclusionPolicy(request.exclusions)
        let volumes = VolumeIdentityResolver()
        var summary = ScanTraversalSummary()
        var pending: [FileObservation] = []
        var pendingIssues: [ScanIssueInfo] = []
        var visited = Set<DirectoryIdentity>()
        var stack: [String] = [request.scope.startPath]

        if case .success(let info) = FileStat.read(request.scope.startPath) {
            visited.insert(DirectoryIdentity(device: info.device, inode: info.inode))
        }

        func flush() async throws {
            guard !pending.isEmpty || !pendingIssues.isEmpty else { return }
            let batch = ScanBatch(
                observations: pending,
                issues: pendingIssues,
                itemsSeen: summary.itemsSeen,
                directoriesVisited: summary.directoriesVisited
            )
            pending.removeAll(keepingCapacity: true)
            pendingIssues.removeAll()
            try await onBatch(batch)
        }

        func report(_ path: String, _ message: String) {
            summary.issueCount += 1
            pendingIssues.append(ScanIssueInfo(path: path, message: message))
        }

        while let directory = stack.popLast() {
            try Task.checkCancellation()
            summary.directoriesVisited += 1

            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory)
            } catch {
                summary.unreadableDirectories.append(directory)
                report(directory, "Folder could not be read: \(Self.describe(error))")
                continue
            }

            for (index, name) in names.enumerated() {
                if index % 512 == 511 {
                    try Task.checkCancellation()
                }
                if policy.isExcludedFile(name) { continue }

                let path = PathUtilities.join(directory, name)
                let info: FileStat
                switch FileStat.read(path) {
                case .success(let value):
                    info = value
                case .failure(let code):
                    report(path, "Item could not be read (\(code.code)).")
                    continue
                }

                let isHidden = name.hasPrefix(".") || info.hasHiddenFlag
                if isHidden && !policy.includeHiddenFiles { continue }

                let volume = volumes.identity(device: info.device, samplePath: directory)
                var observation = Self.makeObservation(
                    path: path, name: name, parent: directory, info: info, isHidden: isHidden, volume: volume
                )

                switch info.kind {
                case .directory:
                    if policy.isExcludedDirectory(name) {
                        continue
                    }
                    if request.skippedSubtrees.contains(path) {
                        // The folder entry belongs to this location; its contents belong to the nested one.
                    } else if !policy.descendIntoPackages && Self.isPackage(path: path, name: name) {
                        let estimate = estimateSize(ofDirectory: path)
                        observation.itemKind = .package
                        observation.uti = observation.fileExtension
                            .flatMap { UTType(filenameExtension: $0, conformingTo: .package) }
                            .flatMap { $0.isDynamic ? nil : $0.identifier } ?? UTType.package.identifier
                        observation.sizeBytes = estimate.bytes
                        observation.allocatedBytes = nil
                        observation.sizeIsEstimate = estimate.isCapped
                    } else if policy.isOpaqueDirectory(name) {
                        let estimate = estimateSize(ofDirectory: path)
                        observation.sizeBytes = estimate.bytes
                        observation.sizeIsEstimate = estimate.isCapped
                    } else if request.scope.depth == .recursive {
                        let identity = DirectoryIdentity(device: info.device, inode: info.inode)
                        if visited.insert(identity).inserted {
                            stack.append(path)
                        } else {
                            report(path, "Folder was already visited through another path and was skipped.")
                        }
                    }
                case .symlink:
                    observation.symlinkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
                case .regular, .other:
                    break
                }

                pending.append(observation)
                summary.itemsSeen += 1
                if pending.count >= request.batchSize {
                    try await flush()
                }
            }

            if pendingIssues.count >= request.batchSize {
                try await flush()
            }
        }

        try await flush()
        return summary
    }

    // MARK: - Helpers

    static func makeObservation(
        path: String,
        name: String,
        parent: String,
        info: FileStat,
        isHidden: Bool,
        volume: String
    ) -> FileObservation {
        let ext = PathUtilities.fileExtension(of: name)
        let kind: ItemKind
        var type: UTType?
        switch info.kind {
        case .regular:
            kind = .regular
            if let ext, let candidate = UTType(filenameExtension: ext), !candidate.isDynamic {
                type = candidate
            }
        case .directory:
            kind = .directory
            type = .folder
        case .symlink:
            kind = .symlink
            type = .symbolicLink
        case .other:
            kind = .other
        }

        return FileObservation(
            path: path,
            filename: name,
            parentPath: parent,
            fileExtension: ext,
            itemKind: kind,
            uti: type?.identifier,
            mimeType: type?.preferredMIMEType,
            sizeBytes: info.kind == .regular ? info.size : 0,
            allocatedBytes: info.kind == .regular ? info.allocatedSize : nil,
            sizeIsEstimate: false,
            createdAt: info.createdAt,
            modifiedAt: info.modifiedAt,
            volumeUUID: volume,
            inode: info.storedInode,
            isHidden: isHidden,
            symlinkTarget: nil
        )
    }

    /// Packages are folders macOS shows as single items. Only folders with an extension can be packages
    /// (bundle-bit packages without one are rare), which avoids a LaunchServices lookup for most folders.
    static func isPackage(path: String, name: String) -> Bool {
        guard let ext = PathUtilities.fileExtension(of: name) else { return false }
        if let type = UTType(filenameExtension: ext, conformingTo: .directory), type.conforms(to: .package) {
            return true
        }
        let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage ?? false
    }

    /// Sums regular-file sizes inside a folder, stopping after `directorySizeEntryLimit` entries.
    func estimateSize(ofDirectory path: String) -> (bytes: Int64, isCapped: Bool) {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return (0, true)
        }
        var total: Int64 = 0
        var count = 0
        while let relative = enumerator.nextObject() as? String {
            count += 1
            if count > directorySizeEntryLimit || (count % 1_000 == 0 && Task.isCancelled) {
                return (total, true)
            }
            if case .success(let info) = FileStat.read(PathUtilities.join(path, relative)), info.kind == .regular {
                total += info.size
            }
        }
        return (total, false)
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
            switch code {
            case .EACCES, .EPERM: return "permission denied"
            case .ENOENT: return "no longer exists"
            default: break
            }
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
            return "permission denied"
        }
        return nsError.localizedDescription
    }
}
