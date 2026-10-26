import AppKit
import FileIntelligenceKit
import Observation
import SwiftUI
import UserNotifications

struct ScanActivity: Equatable {
    var itemsSeen: Int
    var directoriesVisited: Int
    var kind: ScanKind
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Main-actor application state. Views read from it; all work is delegated to `IndexEnvironment` services.
@MainActor
@Observable
final class AppModel {
    let environment: IndexEnvironment

    var selection: SidebarItem? = .overview
    var roots: [RootSummary] = []
    var activeScans: [Int64: ScanActivity] = [:]
    var processing: ProcessingProgress?
    var isProcessing = false
    /// Incremented whenever the index changes; views reload when it does.
    var revision = 0
    var settings: AppSettings
    var alert: AppAlert?

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var rescoreTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: FileMonitor?
    @ObservationIgnored private var lastThrottledRefresh = Date.distantPast
    @ObservationIgnored private var hasStarted = false

    init(environment: IndexEnvironment) {
        self.environment = environment
        self.settings = environment.preferences.loadSettings()
    }

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        listenForEvents()
        await environment.registry.startAccessingEnabledRoots()
        await reloadRoots()
        configureMonitoring()
        scheduleReconciliation()
        await environment.indexing.requestProcessing()
        scanLocationsNeedingAttention()
    }

    private func listenForEvents() {
        let events = environment.indexing.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: IndexingEvent) {
        switch event {
        case .scanStarted(let rootId, let kind):
            activeScans[rootId] = ScanActivity(itemsSeen: 0, directoriesVisited: 0, kind: kind)
        case .scanProgress(let rootId, let itemsSeen, let directoriesVisited):
            activeScans[rootId]?.itemsSeen = itemsSeen
            activeScans[rootId]?.directoriesVisited = directoriesVisited
            refreshThrottled()
        case .scanFinished(let outcome):
            // Only full scans that changed something; change-watching and quiet reconciliation stay silent.
            if activeScans[outcome.rootId]?.kind == .full, outcome.added + outcome.moved + outcome.missing > 0 {
                notify(
                    "Scan of \(rootName(outcome.rootId)) Finished",
                    "\(outcome.added.formatted()) new, \(outcome.moved.formatted()) moved, \(outcome.missing.formatted()) missing."
                )
            }
            activeScans[outcome.rootId] = nil
            refreshNow()
        case .scanFailed(let rootId, let message):
            notify("Scan of \(rootName(rootId)) Failed", message)
            activeScans[rootId] = nil
            refreshNow()
        case .rootUnavailable(let rootId):
            if roots.first(where: { $0.id == rootId })?.root.scanState != .unavailable {
                notify("\(rootName(rootId)) Is Unavailable", "Its files are kept in the index until it’s connected again.")
            }
            activeScans[rootId] = nil
            refreshNow()
        case .scanCancelled(let rootId):
            activeScans[rootId] = nil
            refreshNow()
        case .processingStarted:
            isProcessing = true
        case .processingProgress(let progress):
            processing = progress
            refreshThrottled()
        case .processingFinished:
            isProcessing = false
            processing = nil
            refreshNow()
        case .processingFailed(let message):
            alert = AppAlert(title: "Processing Stopped", message: message)
            notify("Processing Stopped", message)
        }
    }

    /// macOS shows these only while the app is in the background; System Settings controls them.
    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func refreshNow() {
        revision += 1
        lastThrottledRefresh = Date()
        Task { await reloadRoots() }
    }

    private func refreshThrottled() {
        guard Date().timeIntervalSince(lastThrottledRefresh) > 2 else { return }
        refreshNow()
    }

    func reloadRoots() async {
        if let summaries = try? await environment.stats.rootSummaries() {
            roots = summaries
        }
    }

    // MARK: - Locations

    func presentAddLocations() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add to Index"
        panel.message = "Choose folders or drives to index. File Intelligence reads only the locations you choose and never changes files without your confirmation."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addLocations(urls) }
    }

    func addLocations(_ urls: [URL]) async {
        var added: [Int64] = []
        for url in urls {
            do {
                let root = try await environment.registry.addRoot(at: url, exclusions: settings.defaultExclusions)
                if let id = root.id { added.append(id) }
            } catch {
                alert = AppAlert(title: "Couldn’t Add “\(url.lastPathComponent)”", message: error.localizedDescription)
            }
        }
        await reloadRoots()
        configureMonitoring()
        revision += 1
        guard !added.isEmpty else { return }
        let indexing = environment.indexing
        Task {
            for id in added {
                _ = try? await indexing.scan(rootId: id, processAfterwards: false)
            }
            await indexing.requestProcessing()
        }
    }

    func scan(rootId: Int64) {
        let indexing = environment.indexing
        Task {
            do {
                try await indexing.scan(rootId: rootId)
            } catch is CancellationError {
                // Cancelled by the user.
            } catch {
                self.alert = AppAlert(title: "Scan Failed", message: error.localizedDescription)
            }
        }
    }

    func scanAll() {
        let indexing = environment.indexing
        Task { await indexing.scanAllEnabled() }
    }

    func cancelScan(rootId: Int64) {
        let indexing = environment.indexing
        Task { await indexing.cancelScan(rootId: rootId) }
    }

    func setEnabled(_ enabled: Bool, rootId: Int64) {
        perform {
            if !enabled { await self.environment.indexing.cancelScan(rootId: rootId) }
            try await self.environment.registry.setEnabled(enabled, rootId: rootId)
            await self.reloadRoots()
            self.configureMonitoring()
            if enabled { self.scan(rootId: rootId) }
        }
    }

    func removeLocation(rootId: Int64) {
        perform {
            await self.environment.indexing.cancelScan(rootId: rootId)
            try await self.environment.registry.removeRoot(id: rootId)
            await self.reloadRoots()
            self.configureMonitoring()
        }
    }

    func applyDefaultExclusionsToAllLocations() {
        let exclusions = settings.defaultExclusions
        perform {
            for summary in self.roots {
                try await self.environment.registry.updateExclusions(exclusions, rootId: summary.id)
            }
            self.scanAll()
        }
    }

    private func scanLocationsNeedingAttention() {
        let interval = TimeInterval(max(1, settings.reconciliationIntervalHours)) * 3_600
        let now = Date()
        let ids = roots.compactMap { summary -> Int64? in
            let root = summary.root
            guard root.isEnabled else { return nil }
            let stale = root.lastSuccessfulScanAt.map { now.timeIntervalSince($0) > interval } ?? true
            return stale || root.scanState == .interrupted ? summary.id : nil
        }
        guard !ids.isEmpty else { return }
        let indexing = environment.indexing
        Task {
            for id in ids {
                _ = try? await indexing.scan(rootId: id, processAfterwards: false)
            }
            await indexing.requestProcessing()
        }
    }

    // MARK: - Monitoring and reconciliation

    func configureMonitoring() {
        guard settings.monitorFileSystemChanges else {
            monitor?.stop()
            return
        }
        if monitor == nil {
            let indexing = environment.indexing
            monitor = FileMonitor { changes in
                Task { await indexing.applyChanges(changes) }
            }
        }
        let paths = roots
            .filter { $0.root.isEnabled && PathUtilities.isReachableDirectory($0.root.path) }
            .map(\.root.path)
        monitor?.watch(paths)
    }

    private func scheduleReconciliation() {
        reconciliationTask?.cancel()
        let hours = settings.reconciliationIntervalHours
        guard hours > 0 else { return }
        let indexing = environment.indexing
        reconciliationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(hours) * 3_600))
                if Task.isCancelled { break }
                await indexing.scanAllEnabled()
            }
        }
    }

    // MARK: - Settings

    func updateSettings(_ newSettings: AppSettings) {
        guard newSettings != settings else { return }
        let scoringChanged = newSettings.scoring != settings.scoring || newSettings.hashing != settings.hashing
        let monitoringChanged = newSettings.monitorFileSystemChanges != settings.monitorFileSystemChanges
        let intervalChanged = newSettings.reconciliationIntervalHours != settings.reconciliationIntervalHours
        settings = newSettings
        do {
            try environment.preferences.saveSettings(newSettings)
        } catch {
            alert = AppAlert(title: "Couldn’t Save Settings", message: error.localizedDescription)
        }
        if monitoringChanged { configureMonitoring() }
        if intervalChanged { scheduleReconciliation() }
        if scoringChanged {
            // Rescore once the user stops adjusting.
            rescoreTask?.cancel()
            let indexing = environment.indexing
            rescoreTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await indexing.requestProcessing()
            }
        }
    }

    func processNow() {
        let indexing = environment.indexing
        Task { await indexing.requestProcessing() }
    }

    // MARK: - Review decisions

    func setReviewStatus(_ status: ReviewStatus, for ids: [Int64]) {
        perform { try await self.environment.review.setReviewStatus(status, fileIds: ids) }
    }

    func reclassify(_ ids: [Int64], categoryId: Int64) {
        perform { try await self.environment.review.reclassify(fileIds: ids, categoryId: categoryId) }
    }

    func resetClassification(_ ids: [Int64]) {
        perform {
            try await self.environment.review.resetClassification(fileIds: ids)
            await self.environment.indexing.requestProcessing()
        }
    }

    func setPreferredCopy(_ fileId: Int64) {
        perform { try await self.environment.review.setPreferredCopy(fileId: fileId) }
    }

    func verifyDuplicateGroup(_ contentHash: String) {
        perform {
            let stillIdentical = try await self.environment.duplicateDetector.verifyGroup(contentHash: contentHash)
            if !stillIdentical {
                self.alert = AppAlert(
                    title: "Group Changed",
                    message: "Some copies changed since they were indexed, so they are no longer listed as identical."
                )
            }
            await self.environment.indexing.requestProcessing()
        }
    }

    /// Runs an operation, reports failures, and refreshes views afterwards.
    func perform(_ operation: @escaping @MainActor @Sendable () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                self.alert = AppAlert(title: "Something Went Wrong", message: error.localizedDescription)
            }
            self.revision += 1
        }
    }

    // MARK: - File actions

    func moveToTrash(_ ids: [Int64]) {
        let confirm = NSAlert()
        confirm.messageText = ids.count == 1 ? "Move this item to the Trash?" : "Move \(ids.count.formatted()) items to the Trash?"
        confirm.informativeText = "You can restore them from the Trash with Put Back."
        confirm.addButton(withTitle: "Move to Trash")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        runFileOperation(title: "Moved to Trash") { try await $0.moveToTrash(fileIds: ids) }
    }

    private func runFileOperation(
        title: String,
        _ operation: @escaping @Sendable (FileOperationService) async throws -> FileOperationService.Outcome
    ) {
        let service = environment.fileOperations
        perform {
            let outcome: FileOperationService.Outcome
            var messages: [String] = []
            do {
                outcome = try await operation(service)
            } catch let error as FileOperationService.CompletionError {
                outcome = error.outcome
                messages.append(error.localizedDescription)
            }
            messages += outcome.failures.prefix(10)
            if !messages.isEmpty {
                self.alert = AppAlert(
                    title: "Move to Trash Needs Attention",
                    message: messages.joined(separator: "\n")
                )
            }
            if outcome.succeeded > 0 {
                self.notify(title, outcome.succeeded == 1 ? "1 item." : "\(outcome.succeeded.formatted()) items.")
            }
            // Rescan the affected folders so records follow the files (or become missing).
            let changes = outcome.changedFolders.map { DirectoryChange(path: $0, recursive: false) }
            await self.environment.indexing.applyChanges(changes)
        }
    }

    // MARK: - Finder

    func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func rootName(_ rootId: Int64) -> String {
        roots.first { $0.id == rootId }?.root.displayName ?? "Location"
    }
}
