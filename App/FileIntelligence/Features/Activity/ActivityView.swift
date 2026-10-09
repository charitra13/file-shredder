import FileIntelligenceKit
import SwiftUI

struct ActivityView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case scans = "Scans"
        case actions = "Your Decisions"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .scans
    @State private var includeChangeUpdates = false
    @State private var runs: [ScanRunSummary] = []
    @State private var actions: [FileActionRecord] = []
    @State private var selectedRunId: ScanRunSummary.ID?
    @State private var issues: [ScanIssue] = []

    private struct LoadKey: Equatable {
        let mode: Mode
        let includeChangeUpdates: Bool
        let revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Spacer()
                if mode == .scans {
                    Toggle("Include change updates", isOn: $includeChangeUpdates)
                        .toggleStyle(.checkbox)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            switch mode {
            case .scans: scansContent
            case .actions: actionsContent
            }
        }
        .navigationTitle("Activity")
        .task(id: LoadKey(mode: mode, includeChangeUpdates: includeChangeUpdates, revision: model.revision)) {
            await load()
        }
        .task(id: selectedRunId) {
            await loadIssues()
        }
    }

    @ViewBuilder
    private var scansContent: some View {
        if runs.isEmpty {
            ContentUnavailableView("No Scans Yet", systemImage: "clock.arrow.circlepath", description: Text("Scans appear here once a location has been indexed."))
        } else {
            VSplitView {
                Table(runs, selection: $selectedRunId) {
                    TableColumn("Location") { (run: ScanRunSummary) in Text(run.rootName) }
                        .width(min: 100, ideal: 140)
                    TableColumn("Type") { (run: ScanRunSummary) in Text(run.run.kind.displayName) }
                        .width(min: 80, ideal: 100)
                    TableColumn("Started") { (run: ScanRunSummary) in Text(Format.date(run.run.startedAt)) }
                        .width(min: 120, ideal: 150)
                    TableColumn("Duration") { (run: ScanRunSummary) in Text(Format.duration(run.duration)) }
                        .width(min: 60, ideal: 70)
                    TableColumn("Result") { (run: ScanRunSummary) in ScanResultCell(run: run.run) }
                        .width(min: 80, ideal: 100)
                    TableColumn("Items") { (run: ScanRunSummary) in Text(run.run.itemsSeen.formatted()).monospacedDigit() }
                        .width(min: 50, ideal: 70)
                    TableColumn("New") { (run: ScanRunSummary) in Text(run.run.filesAdded.formatted()).monospacedDigit() }
                        .width(min: 40, ideal: 55)
                    TableColumn("Changed") { (run: ScanRunSummary) in Text(run.run.filesUpdated.formatted()).monospacedDigit() }
                        .width(min: 50, ideal: 60)
                    TableColumn("Moved") { (run: ScanRunSummary) in Text(run.run.filesMoved.formatted()).monospacedDigit() }
                        .width(min: 45, ideal: 55)
                    TableColumn("Missing") { (run: ScanRunSummary) in Text(run.run.filesMissing.formatted()).monospacedDigit() }
                        .width(min: 50, ideal: 60)
                }
                .frame(minHeight: 200)
                issuesPane
                    .frame(minHeight: 120)
            }
        }
    }

    @ViewBuilder
    private var issuesPane: some View {
        if let run = runs.first(where: { $0.id == selectedRunId })?.run {
            List {
                Section {
                    if let error = run.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                    }
                    if run.filesRemovedFromIndex > 0 {
                        Text("\(run.filesRemovedFromIndex.formatted()) items left the index because they are now excluded.")
                    }
                    if run.filesInaccessible > 0 {
                        Text("\(run.filesInaccessible.formatted()) items could not be read and are marked Not Readable.")
                    }
                    if issues.isEmpty && run.lastError == nil {
                        Text("No problems were reported.").foregroundStyle(.secondary)
                    }
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.message)
                            Text(PathUtilities.abbreviated(issue.path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Problems (\(run.issuesCount.formatted()))")
                }
            }
        } else {
            Text("Select a scan to see the problems it reported.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var actionsContent: some View {
        if actions.isEmpty {
            ContentUnavailableView("No Decisions Yet", systemImage: "checklist", description: Text("Keep, ignore and reclassify decisions are recorded here."))
        } else {
            Table(actions) {
                TableColumn("Date") { (action: FileActionRecord) in Text(Format.date(action.performedAt)) }
                    .width(min: 120, ideal: 150)
                TableColumn("Action") { (action: FileActionRecord) in Text(action.actionType.displayName) }
                    .width(min: 100, ideal: 140)
                TableColumn("Detail") { (action: FileActionRecord) in Text(action.detail ?? "").foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 140)
                TableColumn("File") { (action: FileActionRecord) in
                    Text(PathUtilities.abbreviated(action.originalPath))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(action.originalPath)
                }
                .width(min: 200, ideal: 400)
                TableColumn("Result") { (action: FileActionRecord) in Text(action.result.rawValue.capitalized) }
                    .width(min: 60, ideal: 80)
            }
        }
    }

    private func load() async {
        let activity = model.environment.activity
        switch mode {
        case .scans:
            let include = includeChangeUpdates
            runs = (try? await activity.recentRuns(limit: 200, includeChangeUpdates: include)) ?? []
        case .actions:
            actions = (try? await activity.recentActions(limit: 500)) ?? []
        }
    }

    private func loadIssues() async {
        guard let runId = selectedRunId else {
            issues = []
            return
        }
        let activity = model.environment.activity
        issues = (try? await activity.issues(runId: runId)) ?? []
    }
}

private struct ScanResultCell: View {
    let run: ScanRun

    var body: some View {
        switch run.state {
        case .completed:
            Text(run.issuesCount > 0 ? "Completed with \(run.issuesCount) problems" : "Completed")
                .foregroundStyle(run.issuesCount > 0 ? Color.orange : Color.primary)
        case .running:
            Text("Running")
        case .cancelled, .interrupted:
            Text(run.state.displayName).foregroundStyle(.secondary)
        case .failed:
            Text("Failed").foregroundStyle(.orange)
        }
    }
}
