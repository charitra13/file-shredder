import Foundation

public struct ScanOutcome: Sendable, Equatable {
    public enum State: String, Sendable {
        case completed
        case cancelled
        case failed
        case unavailable
        case skipped
    }

    public var rootId: Int64
    public var runId: Int64?
    public var state: State
    public var itemsSeen = 0
    public var directoriesVisited = 0
    public var added = 0
    public var updated = 0
    public var unchanged = 0
    public var moved = 0
    public var missing = 0
    public var inaccessible = 0
    public var removedFromIndex = 0
    public var issues = 0

    public init(rootId: Int64, runId: Int64?, state: State) {
        self.rootId = rootId
        self.runId = runId
        self.state = state
    }

    mutating func absorb(_ batch: BatchResult) {
        added += batch.added
        updated += batch.updated
        unchanged += batch.unchanged
        moved += batch.moved
    }

    mutating func absorb(_ nested: ScanOutcome) {
        itemsSeen += nested.itemsSeen
        directoriesVisited += nested.directoriesVisited
        added += nested.added
        updated += nested.updated
        unchanged += nested.unchanged
        moved += nested.moved
        missing += nested.missing
        inaccessible += nested.inaccessible
        removedFromIndex += nested.removedFromIndex
        issues += nested.issues
    }
}

public enum IndexingEvent: Sendable {
    case scanStarted(rootId: Int64, kind: ScanKind)
    case scanProgress(rootId: Int64, itemsSeen: Int, directoriesVisited: Int)
    case scanFinished(ScanOutcome)
    case scanCancelled(rootId: Int64)
    case scanFailed(rootId: Int64, message: String)
    case rootUnavailable(rootId: Int64)
    case processingStarted
    case processingProgress(ProcessingProgress)
    case processingFinished
    case processingFailed(message: String)
}

/// Coordinates scans and post-scan processing.
///
/// - One scan per location at a time; locations are scanned one after another to bound disk I/O.
/// - Metadata is persisted first. Enrichment, classification, hashing and scoring follow as a separate,
///   coalesced processing pass, so the index is usable while slower work continues.
/// - Scans are cancellable. A cancelled or failed scan never marks anything missing.
public actor IndexingService {
    private let registry: RootRegistry
    private let scanner: FileScanner
    private let writer: IndexWriter
    private let pipeline: ProcessingPipeline
    private let batchSize: Int

    private var activeScans: [Int64: Task<ScanOutcome, Error>] = [:]
    private var processingTask: Task<Void, Never>?
    private var processingRequested = false

    public nonisolated let events: AsyncStream<IndexingEvent>
    private nonisolated let continuation: AsyncStream<IndexingEvent>.Continuation

    public init(
        registry: RootRegistry,
        scanner: FileScanner,
        writer: IndexWriter,
        pipeline: ProcessingPipeline,
        batchSize: Int = 500
    ) {
        self.registry = registry
        self.scanner = scanner
        self.writer = writer
        self.pipeline = pipeline
        self.batchSize = batchSize
        let (stream, continuation) = AsyncStream.makeStream(of: IndexingEvent.self, bufferingPolicy: .bufferingNewest(512))
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Status

    public var scanningRootIds: Set<Int64> { Set(activeScans.keys) }

    public var isProcessing: Bool { processingTask != nil }

    // MARK: - Scanning

    /// Scans a whole location. If a full scan of it is already running, waits for that scan instead.
    @discardableResult
    public func scan(rootId: Int64, processAfterwards: Bool = true) async throws -> ScanOutcome {
        let outcome = try await runScan(rootId: rootId, scope: nil)
        if processAfterwards { requestProcessing() }
        return outcome
    }

    /// Scans every enabled location in turn, then processes once.
    public func scanAllEnabled() async {
        let roots = (try? await registry.allRoots()) ?? []
        for root in roots where root.isEnabled {
            guard let id = root.id, !Task.isCancelled else { continue }
            _ = try? await runScan(rootId: id, scope: nil)
        }
        requestProcessing()
    }

    /// Applies filesystem-event changes with targeted scans of the affected folders.
    public func applyChanges(_ changes: [DirectoryChange]) async {
        var processed = Set<DirectoryChange>()
        for change in changes.sorted(by: { $0.path < $1.path }) where !processed.contains(change) {
            processed.insert(change)
            guard let owner = try? await registry.owningRoot(for: change.path), let rootId = owner.id else { continue }
            guard PathUtilities.isReachableDirectory(change.path) else { continue } // the parent's event covers it
            let scope = ScanScope(
                rootPath: owner.path,
                startPath: change.path,
                depth: change.recursive ? .recursive : .shallow
            )
            _ = try? await runScan(rootId: rootId, scope: scope)
        }
        requestProcessing()
    }

    public func cancelScan(rootId: Int64) {
        activeScans[rootId]?.cancel()
    }

    public func cancelAll() {
        for task in activeScans.values { task.cancel() }
        processingTask?.cancel()
    }

    private func runScan(rootId: Int64, scope: ScanScope?) async throws -> ScanOutcome {
        if scope == nil, let running = activeScans[rootId] {
            return try await running.value
        }
        while let running = activeScans[rootId] {
            _ = try? await running.value
            if activeScans[rootId] == running { activeScans[rootId] = nil }
        }
        let task = Task { try await self.performScan(rootId: rootId, scope: scope) }
        activeScans[rootId] = task
        do {
            let outcome = try await task.value
            if activeScans[rootId] == task { activeScans[rootId] = nil }
            return outcome
        } catch {
            if activeScans[rootId] == task { activeScans[rootId] = nil }
            throw error
        }
    }

    private nonisolated func performScan(rootId: Int64, scope requestedScope: ScanScope?) async throws -> ScanOutcome {
        guard let root = try await registry.root(id: rootId) else {
            throw FileIntelligenceError.rootNotFound(rootId)
        }
        guard root.isEnabled else {
            return ScanOutcome(rootId: rootId, runId: nil, state: .skipped)
        }

        let rootPath = try await registry.ensureAccess(rootId: rootId)
        guard PathUtilities.isReachableDirectory(rootPath) else {
            let message = root.rootType == .folder
                ? "“\(root.displayName)” could not be found at \(rootPath). Its index is kept; scan again once it is back."
                : "“\(root.displayName)” is not connected. Its index is kept; reconnect the drive and scan again."
            try writer.markRootUnavailable(rootId: rootId, message: message)
            continuation.yield(.rootUnavailable(rootId: rootId))
            return ScanOutcome(rootId: rootId, runId: nil, state: .unavailable)
        }

        var scope = requestedScope ?? .full(rootPath: rootPath)
        scope.rootPath = rootPath
        let skipped = try await registry.nestedEnabledRootPaths(of: rootId)
        if skipped.contains(where: { PathUtilities.isPath(scope.startPath, inside: $0) }) {
            return ScanOutcome(rootId: rootId, runId: nil, state: .skipped)
        }

        let runId = try writer.beginRun(rootId: rootId, scope: scope, now: Date())
        continuation.yield(.scanStarted(rootId: rootId, kind: scope.kind))
        var outcome = ScanOutcome(rootId: rootId, runId: runId, state: .completed)
        var newDirectories: [String] = []

        do {
            let request = ScanRequest(scope: scope, exclusions: root.exclusions, skippedSubtrees: skipped, batchSize: batchSize)
            let writer = self.writer
            let continuation = self.continuation
            let summary = try await scanner.scan(request) { batch in
                if !batch.observations.isEmpty {
                    let result = try writer.apply(batch.observations, rootId: rootId, runId: runId, now: Date())
                    outcome.absorb(result)
                    newDirectories += result.newDirectoryPaths
                }
                if !batch.issues.isEmpty {
                    try writer.recordIssues(batch.issues, runId: runId)
                }
                outcome.itemsSeen = batch.itemsSeen
                outcome.directoriesVisited = batch.directoriesVisited
                continuation.yield(.scanProgress(
                    rootId: rootId, itemsSeen: batch.itemsSeen, directoriesVisited: batch.directoriesVisited
                ))
            }
            try Task.checkCancellation()

            outcome.itemsSeen = summary.itemsSeen
            outcome.directoriesVisited = summary.directoriesVisited
            outcome.issues = summary.issueCount
            let finalized = try writer.finalize(
                runId: runId, rootId: rootId, scope: scope, skippedSubtrees: skipped, totals: outcome, now: Date()
            )
            outcome.missing = finalized.missing
            outcome.inaccessible = finalized.inaccessible
            outcome.removedFromIndex = finalized.removedFromIndex
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let message = cancelled ? nil : error.localizedDescription
            try? writer.endRun(
                runId: runId, rootId: rootId, state: cancelled ? .cancelled : .failed,
                message: message, totals: outcome, now: Date()
            )
            if cancelled {
                continuation.yield(.scanCancelled(rootId: rootId))
                throw CancellationError()
            }
            continuation.yield(.scanFailed(rootId: rootId, message: error.localizedDescription))
            throw error
        }

        // A shallow scan only lists the top level of folders that appeared; index their contents too.
        if scope.depth == .shallow {
            for directory in newDirectories where !Task.isCancelled {
                let nested = ScanScope(rootPath: rootPath, startPath: directory, depth: .recursive)
                if let subOutcome = try? await performScan(rootId: rootId, scope: nested) {
                    outcome.absorb(subOutcome)
                }
            }
        }

        continuation.yield(.scanFinished(outcome))
        return outcome
    }

    // MARK: - Processing

    /// Starts post-scan processing, or schedules another pass if one is already running.
    public func requestProcessing() {
        if processingTask != nil {
            processingRequested = true
            return
        }
        processingTask = Task { await self.processUntilIdle() }
    }

    /// Runs processing and waits for it (and any pass requested meanwhile) to finish.
    public func processNow() async {
        requestProcessing()
        await processingTask?.value
    }

    private func processUntilIdle() async {
        continuation.yield(.processingStarted)
        repeat {
            processingRequested = false
            do {
                let continuation = self.continuation
                try await pipeline.run { continuation.yield(.processingProgress($0)) }
            } catch is CancellationError {
                break
            } catch {
                continuation.yield(.processingFailed(message: error.localizedDescription))
            }
        } while processingRequested && !Task.isCancelled
        processingTask = nil
        continuation.yield(.processingFinished)
    }
}
