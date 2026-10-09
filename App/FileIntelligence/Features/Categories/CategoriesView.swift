import FileIntelligenceKit
import SwiftUI

struct CategoriesView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: [CategoryStat] = []
    @State private var selectedId: Int64?

    private var technical: [CategoryStat] { stats.filter { $0.category.parentId == nil } }

    private func children(of stat: CategoryStat) -> [CategoryStat] {
        stats.filter { $0.category.parentId == stat.category.id }
    }

    var body: some View {
        HSplitView {
            List(selection: $selectedId) {
                Section("Types") {
                    ForEach(technical) { stat in
                        CategoryRow(stat: stat)
                            .tag(stat.category.id ?? -1)
                        ForEach(children(of: stat).filter { $0.fileCount > 0 }) { child in
                            CategoryRow(stat: child)
                                .padding(.leading, 16)
                                .tag(child.category.id ?? -1)
                        }
                    }
                }
            }
            .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)

            Group {
                if let selected = stats.first(where: { $0.category.id == selectedId }) {
                    FileBrowserView(configuration: .category(selected.category))
                        .id(selected.category.id)
                } else {
                    ContentUnavailableView(
                        "Select a Category",
                        systemImage: "square.grid.2x2",
                        description: Text("Categories are assigned by transparent rules. Each file shows why it was categorised, and you can change any of them.")
                    )
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity)
        }
        .navigationTitle("Categories")
        .task(id: model.revision) {
            let repository = model.environment.categories
            stats = (try? await repository.stats()) ?? []
            if selectedId == nil {
                selectedId = technical.first(where: { $0.fileCount > 0 })?.category.id
            }
        }
    }
}

private struct CategoryRow: View {
    let stat: CategoryStat

    var body: some View {
        HStack {
            Text(stat.category.name)
                .foregroundStyle(stat.fileCount == 0 ? Color.secondary : Color.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(stat.fileCount.formatted())
                    .monospacedDigit()
                if stat.fileCount > 0 {
                    Text(Format.bytes(stat.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
