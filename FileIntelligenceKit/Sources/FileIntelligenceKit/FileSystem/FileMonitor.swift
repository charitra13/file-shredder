import CoreServices
import Foundation

/// A folder whose contents changed, as reported by FSEvents.
public struct DirectoryChange: Sendable, Hashable {
    public var path: String
    /// True when FSEvents could not report precise changes (dropped events) and the subtree must be rescanned.
    public var recursive: Bool

    public init(path: String, recursive: Bool) {
        self.path = path
        self.recursive = recursive
    }
}

/// Watches indexed locations with FSEvents and reports changed folders.
///
/// Events improve responsiveness only. Streams can drop events or stop while the app is not running,
/// so periodic reconciliation scans remain the source of truth.
public final class FileMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable ([DirectoryChange]) -> Void

    private let queue = DispatchQueue(label: "FileIntelligence.FileMonitor")
    private let latency: CFTimeInterval
    private let handler: Handler
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []

    public init(latency: CFTimeInterval = 2.0, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stopStream()
    }

    /// Replaces the watched set. Passing an empty array stops monitoring.
    public func watch(_ paths: [String]) {
        queue.sync {
            let sorted = paths.sorted()
            guard sorted != watchedPaths else { return }
            stopStream()
            watchedPaths = sorted
            startStream()
        }
    }

    public func stop() {
        queue.sync {
            stopStream()
            watchedPaths = []
        }
    }

    // MARK: - Stream lifecycle (always on `queue`)

    private func startStream() {
        guard !watchedPaths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileMonitorCallback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        if FSEventStreamStart(created) {
            stream = created
        } else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
        }
    }

    private func stopStream() {
        guard let current = stream else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
        stream = nil
    }

    fileprivate func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        let mustScanSubdirectories = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        )
        var changes: [String: Bool] = [:]
        for (index, rawPath) in paths.enumerated() {
            let path = PathUtilities.normalized(rawPath)
            let recursive = index < flags.count && (flags[index] & mustScanSubdirectories) != 0
            changes[path] = (changes[path] ?? false) || recursive
        }
        guard !changes.isEmpty else { return }
        handler(changes.map { DirectoryChange(path: $0.key, recursive: $0.value) })
    }
}

private let fileMonitorCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
    guard let info else { return }
    let monitor = Unmanaged<FileMonitor>.fromOpaque(info).takeUnretainedValue()
    let array = unsafeBitCast(eventPaths, to: NSArray.self)
    guard let paths = array as? [String] else { return }
    let flags = (0..<count).map { eventFlags[$0] }
    monitor.receive(paths: paths, flags: flags)
}
