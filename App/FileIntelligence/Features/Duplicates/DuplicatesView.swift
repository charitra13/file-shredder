import FileIntelligenceKit
import SwiftUI

/// Exact duplicate groups (identical SHA-256), largest recoverable storage first.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    @State private var overview: DuplicateOverview?
    @State private var groups: [DuplicateGroupSummary] = []
    @State private var selectedGroupId: DuplicateGroupSummary.ID?
    @State private var members: [FileListItem] = []
    @State private var searchText = ""
    @State private var page = 0
    @State private var loadError: String?

    private let pageSize = 200

    private struct LoadKey: Equatable {
        let text: String
        let page: Int
        let revision: Int
    }

    private struct MembersKey: Equatable {
        let groupId: Int64?
        let revision: Int
    }

    private var selectedGroup: DuplicateGroupSummary? {
        groups.first { $0.id == selectedGroupId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let loadError {
                ContentUnavailableView("Couldn’t Load Duplicates", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No Exact Duplicates",
                    systemImage: "square.on.square",
                    description: Text(model.isProcessing
                        ? "Duplicate checks are still running."
                        : "No indexed files share identical content. Files are compared only when they have the same size.")
                )
            } else {
                HSplitView {
                    groupsTable
                        .frame(minWidth: 380)
                    membersPane
                        .frame(minWidth: 360)
                }
            }
        }
        .navigationTitle("Duplicates")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Name or folder")
        .task(id: LoadKey(text: searchText, page: page, revision: model.revision)) {
            await loadGroups()
        }
        .task(id: MembersKey(groupId: selectedGroupId, revision: model.revision)) {
            await loadMembers()
        }
        .onChange(of: searchText) { _, _ in page = 0 }
    }

    private var header: some View {
        HStack(spacing: 24) {
            if let overview {
                StatInline(title: "Groups", value: overview.groupCount.formatted())
                StatInline(title: "Duplicate files", value: overview.fileCount.formatted())
                StatInline(title: "Potential savings", value: Format.bytes(overview.reclaimableBytes))
            }
            Spacer()
            if groups.count == pageSize || page > 0 {
                Button { page = max(0, page - 1) } label: { Label("Previous Page", systemImage: "chevron.left") }
                    .labelStyle(.iconOnly)
                    .disabled(page == 0)
                Text("Page \(page + 1)").monospacedDigit().foregroundStyle(.secondary)
                Button { page += 1 } label: { Label("Next Page", systemImage: "chevron.right") }
                    .labelStyle(.iconOnly)
                    .disabled(groups.count < pageSize)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var groupsTable: some View {
        Table(groups, selection: $selectedGroupId) {
            TableColumn("Example") { (group: DuplicateGroupSummary) in
                Text(group.referenceFilename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.referencePath)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Copies") { (group: DuplicateGroupSummary) in
                Text(group.fileCount.formatted()).monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Size Each") { (group: DuplicateGroupSummary) in
                Text(Format.bytes(group.sizeBytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Recoverable") { (group: DuplicateGroupSummary) in
                Text(Format.bytes(group.reclaimableBytes)).monospacedDigit()
            }
            .width(min: 80, ideal: 100)
        }
    }

    @ViewBuilder
    private var membersPane: some View {
        if let group = selectedGroup {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.fileCount) identical copies, \(Format.bytes(group.sizeBytes)) each")
                        .font(.headline)
                    Text("Verified byte-for-byte identical (SHA-256). Choose the copy to keep; the others become review candidates. Nothing is removed automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Verify Again") { model.verifyDuplicateGroup(group.contentHash) }
                            .help("Re-read every copy from disk and confirm they are still identical")
                        Button("Reveal All in Finder") { model.reveal(members.map(\.path)) }
                    }
                    .padding(.top, 4)
                }
                .padding()
                Divider()
                List(members) { member in
                    DuplicateMemberRow(
                        member: member,
                        isReference: group.referenceFileId == member.id,
                        isPreferred: group.preferredFileId == member.id
                    )
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Group",
                systemImage: "square.on.square",
                description: Text("Choose a duplicate group to see every location of the file.")
            )
        }
    }

    private func loadGroups() async {
        let repository = model.environment.duplicates
        let offset = page * pageSize
        let limit = pageSize
        let text = searchText
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        do {
            async let fetchedOverview = repository.overview()
            async let fetchedGroups = repository.groups(offset: offset, limit: limit, text: text)
            let (newOverview, newGroups) = try await (fetchedOverview, fetchedGroups)
            overview = newOverview
            groups = newGroups
            loadError = nil
            if let selectedGroupId, !newGroups.contains(where: { $0.id == selectedGroupId }) {
                self.selectedGroupId = nil
            }
            if selectedGroupId == nil {
                selectedGroupId = newGroups.first?.id
            }
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadMembers() async {
        guard let group = selectedGroup else {
            members = []
            return
        }
        let repository = model.environment.duplicates
        let hash = group.contentHash
        members = (try? await repository.members(contentHash: hash)) ?? []
    }
}

private struct DuplicateMemberRow: View {
    let member: FileListItem
    let isReference: Bool
    let isPreferred: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            FileIconView(uti: member.uti, kind: member.itemKind, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(member.filename).lineLimit(1).truncationMode(.middle)
                    if isPreferred {
                        Text("Your choice").font(.caption).foregroundStyle(.secondary)
                    } else if isReference {
                        Text("Reference copy").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(PathUtilities.abbreviated(member.parentPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Text("\(member.rootName) · Modified \(Format.date(member.modifiedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Keep This Copy") { model.setPreferredCopy(member.id) }
                    .disabled(isPreferred)
                HStack(spacing: 8) {
                    Button("Reveal") { model.reveal([member.path]) }
                    PriorityBadge(priority: member.cleanupPriority, status: member.reviewStatus)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Reveal in Finder") { model.reveal([member.path]) }
            Button("Keep This Copy") { model.setPreferredCopy(member.id) }
            Divider()
            Button("Keep") { model.setReviewStatus(.keep, for: [member.id]) }
            Button("Ignore Suggestion") { model.setReviewStatus(.ignored, for: [member.id]) }
            Divider()
            Button("Move to Trash…") { model.moveToTrash([member.id]) }
        }
    }
}

struct StatInline: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
