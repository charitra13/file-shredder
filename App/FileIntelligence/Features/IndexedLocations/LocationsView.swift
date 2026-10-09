import FileIntelligenceKit
import SwiftUI

struct LocationsView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: RootSummary?

    var body: some View {
        Group {
            if model.roots.isEmpty {
                ContentUnavailableView {
                    Label("No Indexed Locations", systemImage: "folder.badge.plus")
                } description: {
                    Text("Choose the folders and drives you want File Intelligence to understand, such as Downloads, Documents or a project folder. macOS asks for permission when you choose them; the app never reads anything else.")
                } actions: {
                    Button("Add Location…") { model.presentAddLocations() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        ForEach(model.roots) { summary in
                            LocationRow(
                                summary: summary,
                                activity: model.activeScans[summary.id],
                                onRemove: { pendingRemoval = summary }
                            )
                        }
                    } footer: {
                        Text("Locations can overlap; each file is indexed once, by the innermost enabled location. Removing a location only removes it from the index. Files on disk are never deleted or moved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Indexed Locations")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.presentAddLocations()
                } label: {
                    Label("Add Location", systemImage: "plus")
                }
                .help("Add folders or drives to the index")
                Button {
                    model.scanAll()
                } label: {
                    Label("Scan All", systemImage: "arrow.clockwise")
                }
                .help("Rescan every enabled location")
                .disabled(model.roots.isEmpty)
            }
        }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.root.displayName ?? "")” from the index?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { summary in
            Button("Remove from Index", role: .destructive) {
                model.removeLocation(rootId: summary.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { summary in
            Text("\(summary.itemCount.formatted()) items and their review decisions will be forgotten. Files in “\(summary.root.path)” are not deleted or changed. If another indexed location contains this folder, it keeps the items.")
        }
    }
}

private struct LocationRow: View {
    let summary: RootSummary
    let activity: ScanActivity?
    let onRemove: () -> Void

    @Environment(AppModel.self) private var model

    private var root: ScanRoot { summary.root }

    private var icon: String {
        switch root.rootType {
        case .folder: return "folder"
        case .externalVolume: return "externaldrive"
        case .networkVolume: return "network"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(root.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(root.displayName).font(.headline)
                    Text(root.rootType.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(PathUtilities.abbreviated(root.path))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
                if let container = summary.nestedInside {
                    Text("Inside “\(container)”. Items here are indexed by this location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(summary.itemCount.formatted()) items")
                    .monospacedDigit()
                Text(Format.bytes(summary.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if summary.missingCount > 0 {
                    Text("\(summary.missingCount.formatted()) missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            controls
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let activity {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(activity.kind == .full ? "Scanning" : "Updating")… \(activity.itemsSeen.formatted()) items")
            }
            .font(.caption)
        } else if !root.isEnabled {
            Text("Paused. The existing index is kept but not updated.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch root.scanState {
            case .unavailable:
                Label(root.lastError ?? "Not reachable. Its index is kept until it is back.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .failed:
                Label(root.lastError ?? "The last scan failed.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .interrupted:
                Text("The last scan was interrupted. Scan again to finish; nothing was marked missing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle, .scanning:
                Text(root.lastSuccessfulScanAt == nil ? "Not scanned yet" : "Last full scan \(Format.relative(root.lastSuccessfulScanAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if activity != nil {
                Button("Stop") { model.cancelScan(rootId: summary.id) }
            } else {
                Button("Scan Now") { model.scan(rootId: summary.id) }
                    .disabled(!root.isEnabled)
            }
            Menu {
                Button(root.isEnabled ? "Pause Indexing" : "Resume Indexing") {
                    model.setEnabled(!root.isEnabled, rootId: summary.id)
                }
                Button("Reveal in Finder") { model.reveal([root.path]) }
                Divider()
                Button("Remove from Index…", role: .destructive) { onRemove() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
    }
}
