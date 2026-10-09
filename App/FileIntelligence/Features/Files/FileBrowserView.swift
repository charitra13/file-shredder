import FileIntelligenceKit
import SwiftUI

enum SizeFilter: String, CaseIterable, Identifiable {
    case any
    case over10MB
    case over100MB
    case over500MB
    case over1GB
    case over5GB

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "Any Size"
        case .over10MB: return "Over 10 MB"
        case .over100MB: return "Over 100 MB"
        case .over500MB: return "Over 500 MB"
        case .over1GB: return "Over 1 GB"
        case .over5GB: return "Over 5 GB"
        }
    }

    var minimum: Int64? {
        let megabyte: Int64 = 1_000_000
        switch self {
        case .any: return nil
        case .over10MB: return 10 * megabyte
        case .over100MB: return 100 * megabyte
        case .over500MB: return 500 * megabyte
        case .over1GB: return 1_000 * megabyte
        case .over5GB: return 5_000 * megabyte
        }
    }
}

struct FileBrowserConfiguration {
    var title: String
    var baseQuery: FileQuery
    var initialSize: SizeFilter = .any
    var showsCategoryFilter = true
    var note: String?
    var emptyTitle: String
    var emptyMessage: String
    var emptySystemImage: String

    static let allFiles = FileBrowserConfiguration(
        title: "All Files",
        baseQuery: FileQuery(),
        emptyTitle: "No Files",
        emptyMessage: "No indexed files match. Add a location or change the filters.",
        emptySystemImage: "doc.on.doc"
    )

    static let largeFiles = FileBrowserConfiguration(
        title: "Large Files",
        baseQuery: FileQuery(itemKinds: [.regular, .package], sortField: .size, ascending: false),
        initialSize: .over100MB,
        emptyTitle: "No Large Files",
        emptyMessage: "No indexed files are above the selected size.",
        emptySystemImage: "arrow.up.left.and.arrow.down.right"
    )

    static func reviewCandidates(minimumPriority: Int) -> FileBrowserConfiguration {
        FileBrowserConfiguration(
            title: "Review Candidates",
            baseQuery: FileQuery(
                itemKinds: [.regular, .package],
                reviewStatuses: [.unreviewed, .reviewLater],
                minimumCleanupPriority: minimumPriority,
                sortField: .priority,
                ascending: false
            ),
            note: "Files with explainable reasons to review them: duplicates, temporary files, old installers, large archives and more. Mark files Keep or Ignore to stop suggestions. Nothing is moved or deleted.",
            emptyTitle: "Nothing to Review",
            emptyMessage: "No files currently have reasons to be reviewed.",
            emptySystemImage: "checkmark.seal"
        )
    }

    static func category(_ category: FileCategory) -> FileBrowserConfiguration {
        FileBrowserConfiguration(
            title: category.name,
            baseQuery: FileQuery(categoryId: category.id, itemKinds: [.regular, .package, .symlink, .other]),
            showsCategoryFilter: false,
            note: category.description,
            emptyTitle: "No \(category.name)",
            emptyMessage: "No indexed files are in this category.",
            emptySystemImage: "square.grid.2x2"
        )
    }
}

/// A sortable, filterable, paginated list over the index, with a details inspector.
struct FileBrowserView: View {
    let configuration: FileBrowserConfiguration

    @Environment(AppModel.self) private var model

    @State private var items: [FileListItem] = []
    @State private var summary = QuerySummary(count: 0, totalBytes: 0)
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoaded = false
    @State private var searchText = ""
    @State private var categoryFilter: Int64?
    @State private var rootFilter: Int64?
    @State private var sizeFilter: SizeFilter
    @State private var includeUnavailable = false
    @State private var sortOrder: [KeyPathComparator<FileListItem>]
    @State private var page = 0
    @State private var selection = Set<FileListItem.ID>()
    @State private var showInspector = true
    @State private var categories: [FileCategory] = []

    private let pageSize = 200

    init(configuration: FileBrowserConfiguration) {
        self.configuration = configuration
        _sizeFilter = State(initialValue: configuration.initialSize)
        _sortOrder = State(initialValue: [Self.comparator(for: configuration.baseQuery)])
    }

    private struct LoadKey: Equatable {
        let query: FileQuery
        let page: Int
        let revision: Int
    }

    private var query: FileQuery {
        var query = configuration.baseQuery
        query.text = searchText
        if let categoryFilter { query.categoryId = categoryFilter }
        if let rootFilter { query.rootId = rootFilter }
        if let minimum = sizeFilter.minimum { query.minimumSize = max(query.minimumSize ?? 0, minimum) }
        if includeUnavailable { query.availability = nil }
        let sort = Self.sort(from: sortOrder.first)
        query.sortField = sort.field
        query.ascending = sort.ascending
        return query
    }

    private var pageCount: Int {
        max(1, Int((Double(summary.count) / Double(pageSize)).rounded(.up)))
    }

    private var selectedItems: [FileListItem] {
        items.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if let note = configuration.note, !note.isEmpty {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .navigationTitle(configuration.title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Name or folder")
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide file details")
            }
        }
        .inspector(isPresented: $showInspector) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .task(id: LoadKey(query: query, page: page, revision: model.revision)) {
            await load()
        }
        .task {
            categories = (try? await model.environment.categories.all()) ?? []
        }
        .onChange(of: query) { _, _ in
            page = 0
        }
    }

    // MARK: - Sections

    private var filterBar: some View {
        HStack(spacing: 12) {
            if configuration.showsCategoryFilter {
                Picker("Category", selection: $categoryFilter) {
                    Text("All Categories").tag(Int64?.none)
                    Divider()
                    ForEach(categories) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .frame(maxWidth: 230)
            }
            Picker("Location", selection: $rootFilter) {
                Text("All Locations").tag(Int64?.none)
                Divider()
                ForEach(model.roots) { summary in
                    Text(summary.root.displayName).tag(summary.root.id)
                }
            }
            .frame(maxWidth: 230)
            Picker("Size", selection: $sizeFilter) {
                ForEach(SizeFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .frame(maxWidth: 170)
            Toggle("Include missing and unavailable", isOn: $includeUnavailable)
                .toggleStyle(.checkbox)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Couldn’t Load Files",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if model.roots.isEmpty {
            ContentUnavailableView {
                Label("No Indexed Locations", systemImage: "folder.badge.plus")
            } description: {
                Text("Add folders or drives to build your file index. Files stay where they are.")
            } actions: {
                Button("Add Location…") { model.presentAddLocations() }
            }
        } else if items.isEmpty && hasLoaded && !isLoading {
            ContentUnavailableView(
                configuration.emptyTitle,
                systemImage: configuration.emptySystemImage,
                description: Text(configuration.emptyMessage)
            )
        } else {
            table
        }
    }

    private var table: some View {
        Table(items, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \FileListItem.filename) { (item: FileListItem) in
                FileNameCell(item: item)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Category", value: \FileListItem.categoryName) { (item: FileListItem) in
                SecondaryCell(text: item.categoryName.isEmpty ? "—" : item.categoryName)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Size", value: \FileListItem.sizeBytes) { (item: FileListItem) in
                SizeCell(item: item)
            }
            .width(min: 70, ideal: 85)
            TableColumn("Modified", value: \FileListItem.modifiedSortKey) { (item: FileListItem) in
                SecondaryCell(text: Format.date(item.modifiedAt))
            }
            .width(min: 120, ideal: 150)
            TableColumn("Priority", value: \FileListItem.prioritySortKey) { (item: FileListItem) in
                PriorityBadge(priority: item.cleanupPriority, status: item.reviewStatus)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Reason", value: \FileListItem.reasonSortKey) { (item: FileListItem) in
                SecondaryCell(text: item.topReason ?? "")
            }
            .width(min: 120, ideal: 240)
            TableColumn("Location", value: \FileListItem.parentPath) { (item: FileListItem) in
                LocationCell(path: item.parentPath)
            }
            .width(min: 140, ideal: 260)
        }
        .contextMenu(forSelectionType: FileListItem.ID.self) { ids in
            FileContextMenu(items: items.filter { ids.contains($0.id) }, categories: categories)
        } primaryAction: { ids in
            let paths = items.filter { ids.contains($0.id) }.map(\.path)
            model.reveal(paths)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(summary.count.formatted()) items, \(Format.bytes(summary.totalBytes))")
            if !selection.isEmpty {
                Text("\(selection.count.formatted()) selected")
            }
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if pageCount > 1 {
                Button {
                    page = max(0, page - 1)
                } label: {
                    Label("Previous Page", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .disabled(page == 0)
                Text("Page \(page + 1) of \(pageCount)")
                    .monospacedDigit()
                Button {
                    page = min(pageCount - 1, page + 1)
                } label: {
                    Label("Next Page", systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .disabled(page >= pageCount - 1)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var inspector: some View {
        let selected = selectedItems
        if selected.count == 1, let item = selected.first {
            FileDetailView(fileId: item.id)
        } else if selected.count > 1 {
            BulkSelectionView(items: selected, categories: categories)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.trailing",
                description: Text("Select a file to see its details, or several files to review them together.")
            )
        }
    }

    // MARK: - Loading

    private func load() async {
        let query = self.query
        let offset = page * pageSize
        // Debounce typing: a newer key cancels this task during the pause.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        let files = model.environment.files
        let limit = pageSize
        do {
            async let pageItems = files.fetchPage(query, offset: offset, limit: limit)
            async let pageSummary = files.summary(query)
            let (newItems, newSummary) = try await (pageItems, pageSummary)
            guard !Task.isCancelled else { return }
            items = newItems
            summary = newSummary
            loadError = nil
            hasLoaded = true
            let visible = Set(newItems.map(\.id))
            selection = selection.intersection(visible)
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Sorting

    static func comparator(for query: FileQuery) -> KeyPathComparator<FileListItem> {
        let order: SortOrder = query.ascending ? .forward : .reverse
        switch query.sortField {
        case .name: return KeyPathComparator(\FileListItem.filename, order: order)
        case .size: return KeyPathComparator(\FileListItem.sizeBytes, order: order)
        case .modified, .created: return KeyPathComparator(\FileListItem.modifiedSortKey, order: order)
        case .category: return KeyPathComparator(\FileListItem.categoryName, order: order)
        case .priority: return KeyPathComparator(\FileListItem.prioritySortKey, order: order)
        case .location: return KeyPathComparator(\FileListItem.parentPath, order: order)
        }
    }

    static func sort(from comparator: KeyPathComparator<FileListItem>?) -> (field: FileSortField, ascending: Bool) {
        guard let comparator else { return (.name, true) }
        let ascending = comparator.order == .forward
        let keyPath = comparator.keyPath
        let field: FileSortField
        if keyPath == \FileListItem.sizeBytes as PartialKeyPath<FileListItem> {
            field = .size
        } else if keyPath == \FileListItem.modifiedSortKey as PartialKeyPath<FileListItem> {
            field = .modified
        } else if keyPath == \FileListItem.categoryName as PartialKeyPath<FileListItem> {
            field = .category
        } else if keyPath == \FileListItem.prioritySortKey as PartialKeyPath<FileListItem> {
            field = .priority
        } else if keyPath == \FileListItem.parentPath as PartialKeyPath<FileListItem> {
            field = .location
        } else {
            field = .name
        }
        return (field, ascending)
    }
}

// MARK: - Cells

private struct FileNameCell: View {
    let item: FileListItem

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(uti: item.uti, kind: item.itemKind)
            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.isDuplicate {
                Image(systemName: "square.on.square")
                    .foregroundStyle(.secondary)
                    .help("Has identical copies")
                    .accessibilityLabel("Has identical copies")
            }
            AvailabilityBadge(availability: item.availability)
        }
        .help(item.path)
    }
}

private struct SecondaryCell: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(text)
    }
}

private struct SizeCell: View {
    let item: FileListItem

    var body: some View {
        Text(item.itemKind == .directory ? "—" : Format.bytes(item.sizeBytes))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct LocationCell: View {
    let path: String

    var body: some View {
        Text(PathUtilities.abbreviated(path))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .help(path)
    }
}
