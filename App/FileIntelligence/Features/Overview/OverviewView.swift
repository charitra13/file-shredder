import FileIntelligenceKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: OverviewStats?
    @State private var recentRuns: [ScanRunSummary] = []
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.roots.isEmpty {
                    welcome
                } else if let stats {
                    tiles(stats)
                    actions(stats)
                    recentActivity
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .frame(maxWidth: 1_100, alignment: .leading)
        }
        .navigationTitle("Overview")
        .task(id: model.revision) {
            await load()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Understand what is on your Mac")
                .font(.largeTitle.weight(.semibold))
            Text("File Intelligence builds a private index of the folders and drives you choose. It identifies file types, finds exact duplicates and large files, and explains which files might be worth reviewing. Everything stays on this Mac, and nothing is moved or deleted unless you decide to.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add a Location…") { model.presentAddLocations() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func tiles(_ stats: OverviewStats) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            StatTile(title: "Indexed items", value: stats.totalItems.formatted(), detail: "\(stats.totalFolders.formatted()) folders", systemImage: "doc.on.doc") {
                model.selection = .allFiles
            }
            StatTile(title: "Indexed storage", value: Format.bytes(stats.totalBytes), detail: "Across \(stats.enabledLocationCount) active locations", systemImage: "internaldrive") {
                model.selection = .largeFiles
            }
            StatTile(title: "Locations", value: stats.locationCount.formatted(), detail: stats.unavailableLocationCount > 0 ? "\(stats.unavailableLocationCount) unavailable" : "All reachable", systemImage: "folder") {
                model.selection = .locations
            }
            StatTile(title: "Awaiting review", value: stats.reviewCandidates.formatted(), detail: Format.bytes(stats.reviewCandidateBytes), systemImage: "tray.full") {
                model.selection = .review
            }
            StatTile(title: "Exact duplicate groups", value: stats.duplicateGroups.formatted(), detail: "\(stats.duplicateFiles.formatted()) files", systemImage: "square.on.square") {
                model.selection = .duplicates
            }
            StatTile(title: "Potential savings", value: Format.bytes(stats.reclaimableBytes), detail: "From exact duplicates", systemImage: "arrow.down.circle") {
                model.selection = .duplicates
            }
            StatTile(title: "Classified", value: stats.classifiedItems.formatted(), detail: "\(stats.unclassifiedItems.formatted()) unclassified", systemImage: "square.grid.2x2") {
                model.selection = .categories
            }
            StatTile(title: "Missing or unavailable", value: (stats.missingItems + stats.unavailableItems).formatted(), detail: "Kept in the index with their decisions", systemImage: "questionmark.folder") {
                model.selection = .locations
            }
        }
        if stats.pendingProcessing > 0 || model.isProcessing {
            Label(
                "\(stats.pendingProcessing.formatted()) items are still being analysed. Figures update as processing continues.",
                systemImage: "hourglass"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func actions(_ stats: OverviewStats) -> some View {
        HStack(spacing: 10) {
            Button("Add Location…") { model.presentAddLocations() }
            Button("Scan All Locations") { model.scanAll() }
            Button("Review Candidates") { model.selection = .review }
                .disabled(stats.reviewCandidates == 0)
            Button("Search Files") { model.selection = .allFiles }
        }
    }

    @ViewBuilder
    private var recentActivity: some View {
        if !recentRuns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Indexing")
                    .font(.headline)
                ForEach(recentRuns) { summary in
                    HStack {
                        Text(summary.rootName)
                        Text(summary.run.kind.displayName).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(summary.run.itemsSeen.formatted()) items, \(summary.run.filesAdded.formatted()) new, \(summary.run.filesMissing.formatted()) missing")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(summary.run.state.displayName)
                            .frame(width: 90, alignment: .trailing)
                        Text(Format.relative(summary.run.finishedAt ?? summary.run.startedAt))
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .trailing)
                    }
                    .font(.callout)
                    Divider()
                }
            }
        }
    }

    private func load() async {
        let statsRepository = model.environment.stats
        let activity = model.environment.activity
        do {
            async let fetchedStats = statsRepository.overview()
            async let fetchedRuns = activity.recentRuns(limit: 6)
            let (newStats, newRuns) = try await (fetchedStats, fetchedRuns)
            stats = newStats
            recentRuns = newRuns
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }
}
