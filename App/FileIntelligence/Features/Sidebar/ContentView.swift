import FileIntelligenceKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview
    case allFiles
    case categories
    case duplicates
    case largeFiles
    case review
    case locations
    case activity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .allFiles: return "All Files"
        case .categories: return "Categories"
        case .duplicates: return "Duplicates"
        case .largeFiles: return "Large Files"
        case .review: return "Review Candidates"
        case .locations: return "Indexed Locations"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .allFiles: return "doc.on.doc"
        case .categories: return "square.grid.2x2"
        case .duplicates: return "square.on.square"
        case .largeFiles: return "arrow.up.left.and.arrow.down.right"
        case .review: return "tray.full"
        case .locations: return "folder.badge.gearshape"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .allFiles: return "2"
        case .categories: return "3"
        case .duplicates: return "4"
        case .largeFiles: return "5"
        case .review: return "6"
        case .locations: return "7"
        case .activity: return "8"
        case .settings: return "9"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Library") {
                    row(.overview)
                    row(.allFiles)
                    row(.categories)
                }
                Section("Storage") {
                    row(.duplicates)
                    row(.largeFiles)
                    row(.review)
                }
                Section("Index") {
                    row(.locations)
                    row(.activity)
                    row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                IndexStatusView()
                    .padding(10)
            }
        } detail: {
            detail(for: model.selection ?? .overview)
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(item)
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .overview:
            OverviewView()
        case .allFiles:
            FileBrowserView(configuration: .allFiles)
        case .categories:
            CategoriesView()
        case .duplicates:
            DuplicatesView()
        case .largeFiles:
            FileBrowserView(configuration: .largeFiles)
        case .review:
            FileBrowserView(configuration: .reviewCandidates(minimumPriority: model.settings.scoring.minimumCandidatePriority))
                .id(model.settings.scoring.minimumCandidatePriority)
        case .locations:
            LocationsView()
        case .activity:
            ActivityView()
        case .settings:
            SettingsView()
        }
    }
}

/// Compact indexing status shown at the bottom of the sidebar.
struct IndexStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scan = model.activeScans.first {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning \(model.rootName(scan.key))")
                        .lineLimit(1)
                }
                Text("\(scan.value.itemsSeen.formatted()) items found")
                    .foregroundStyle(.secondary)
            } else if model.isProcessing {
                Text(model.processing?.stage.displayName ?? "Processing")
                    .lineLimit(1)
                if let fraction = model.processing?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            } else if model.roots.isEmpty {
                Label("No locations yet", systemImage: "folder.badge.plus")
                    .foregroundStyle(.secondary)
            } else {
                Label("Index up to date", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
