import FileIntelligenceKit
import SwiftUI

/// Everything the index knows about one file, with the reasoning behind each conclusion.
struct FileDetailView: View {
    let fileId: Int64

    @Environment(AppModel.self) private var model
    @State private var detail: FileDetail?
    @State private var categories: [FileCategory] = []
    @State private var loadError: String?

    private struct LoadKey: Equatable {
        let fileId: Int64
        let revision: Int
    }

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let loadError {
                ContentUnavailableView("Couldn’t Load Details", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(fileId: fileId, revision: model.revision)) {
            await load()
        }
    }

    private func load() async {
        let files = model.environment.files
        let categoryRepository = model.environment.categories
        let id = fileId
        do {
            async let fetched = files.detail(fileId: id)
            async let allCategories = categoryRepository.all()
            let (value, list) = try await (fetched, allCategories)
            detail = value
            categories = list
            loadError = value == nil ? "This file is no longer in the index." : nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func content(_ detail: FileDetail) -> some View {
        let file = detail.file
        let item = listItem(for: detail)
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    FileIconView(uti: file.uti, kind: file.itemKind, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename)
                            .font(.headline)
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Text(Format.typeDescription(uti: file.uti, kind: file.itemKind))
                            .foregroundStyle(.secondary)
                        AvailabilityBadge(availability: file.availability)
                    }
                }
                HStack {
                    Button("Reveal in Finder") { model.reveal([file.path]) }
                    if let item {
                        Button("Open") { model.open(file.path) }
                            .disabled(!FileOpenPolicy.canOpen(item))
                    }
                }
            }

            recommendationSection(file)
            classificationSection(detail)
            informationSection(detail)
            if let metadata = detail.metadata {
                mediaSection(metadata)
            }
            if detail.duplicateGroup != nil {
                duplicatesSection(detail)
            }
            if !detail.relationships.isEmpty {
                relationshipsSection(detail)
            }
            if !detail.actions.isEmpty {
                historySection(detail)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    @ViewBuilder
    private func recommendationSection(_ file: FileRecord) -> some View {
        let ids = [file.id].compactMap { $0 }
        Section("Review") {
            LabeledContent("Decision", value: file.reviewStatus.displayName)
            if file.reviewStatus.suppressesRecommendations {
                Text("Suggestions for this file are turned off by your decision.")
                    .foregroundStyle(.secondary)
            } else if let reasons = file.cleanupReasons, !reasons.isEmpty, let priority = file.cleanupPriority {
                LabeledContent("Priority", value: "\(priority) of 100")
                ForEach(reasons, id: \.self) { reason in
                    Label {
                        Text(reason.message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: reason.weight > 0 ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundStyle(reason.weight > 0 ? Color.orange : Color.secondary)
                    }
                    .help(reason.weight > 0 ? "Raises the priority by \(reason.weight)" : "Lowers the priority by \(-reason.weight)")
                }
                PriorityDisclaimer()
            } else if file.scoredAt == nil && (file.itemKind == .regular || file.itemKind == .package) {
                Text("Not evaluated yet.").foregroundStyle(.secondary)
            } else {
                Text("No reasons to review this file.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Keep") { model.setReviewStatus(.keep, for: ids) }
                    .disabled(file.reviewStatus == .keep)
                Button("Ignore") { model.setReviewStatus(.ignored, for: ids) }
                    .disabled(file.reviewStatus == .ignored)
                Button("Later") { model.setReviewStatus(.reviewLater, for: ids) }
                    .disabled(file.reviewStatus == .reviewLater)
                if file.reviewStatus != .unreviewed {
                    Button("Clear") { model.setReviewStatus(.unreviewed, for: ids) }
                }
            }
        }
    }

    @ViewBuilder
    private func classificationSection(_ detail: FileDetail) -> some View {
        let file = detail.file
        let ids = [file.id].compactMap { $0 }
        Section("Classification") {
            LabeledContent("Category", value: detail.category?.name ?? (file.itemKind == .directory ? "Not classified (folder)" : "None"))
            LabeledContent("Source", value: file.classificationSource.displayName)
            if let confidence = file.classificationConfidence, file.classificationSource != .user {
                LabeledContent("Confidence", value: Format.percent(confidence))
            }
            if let explanation = file.classificationExplanation {
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !detail.tags.isEmpty {
                LabeledContent("Tags") {
                    Text(detail.tags.map { $0.source == .rule ? "\($0.tag) (suggested)" : $0.tag }.joined(separator: ", "))
                }
            }
            if file.itemKind != .directory {
                HStack {
                    CategoryMenu(title: "Change Category", categories: categories) { categoryId in
                        model.reclassify(ids, categoryId: categoryId)
                    }
                    .fixedSize()
                    if file.classificationSource == .user {
                        Button("Use Automatic") { model.resetClassification(ids) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func informationSection(_ detail: FileDetail) -> some View {
        let file = detail.file
        Section("Information") {
            if file.itemKind != .directory {
                LabeledContent("Size", value: Format.bytes(file.sizeBytes) + (file.sizeIsEstimate ? " (estimate)" : ""))
            }
            if let allocated = file.allocatedBytes, allocated != file.sizeBytes {
                LabeledContent("On disk", value: Format.bytes(allocated))
            }
            LabeledContent("Kind", value: file.itemKind.displayName)
            if let uti = file.uti {
                LabeledContent("Type identifier") { Text(uti).textSelection(.enabled) }
            }
            if let signature = file.detectedSignature.flatMap(FormatSignature.init(rawValue:)) {
                LabeledContent("Contents look like", value: signature.displayName)
            }
            if let target = file.symlinkTarget {
                LabeledContent("Points to") { Text(target).textSelection(.enabled) }
            }
            LabeledContent("Created", value: Format.date(file.createdAt))
            LabeledContent("Modified", value: Format.date(file.modifiedAt))
            LabeledContent("Folder") {
                Text(PathUtilities.abbreviated(file.parentPath))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.head)
            }
            LabeledContent("Indexed location", value: detail.root?.displayName ?? "—")
            LabeledContent("First indexed", value: Format.date(file.firstIndexedAt))
            LabeledContent("Last seen", value: Format.date(file.lastSeenAt))
            if let missingSince = file.missingSince {
                LabeledContent("Missing since", value: Format.date(missingSince))
            }
        }
    }

    @ViewBuilder
    private func mediaSection(_ metadata: FileMetadataRecord) -> some View {
        Section("Media") {
            if let width = metadata.pixelWidth, let height = metadata.pixelHeight {
                LabeledContent("Dimensions", value: "\(width) × \(height)")
            }
            if let duration = metadata.durationSeconds {
                LabeledContent("Duration", value: Format.duration(duration))
            }
            if let pages = metadata.pageCount {
                LabeledContent("Pages", value: pages.formatted())
            }
            if let codec = metadata.videoCodec, !codec.isEmpty {
                LabeledContent("Codec", value: codec)
            }
            if let language = metadata.sourceLanguage {
                LabeledContent("Language", value: language)
            }
            if let error = metadata.extractionError {
                Text(error).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func duplicatesSection(_ detail: FileDetail) -> some View {
        let group = detail.duplicateGroup
        Section {
            ForEach(detail.duplicateCopies) { copy in
                HStack {
                    VStack(alignment: .leading) {
                        Text(copy.filename).lineLimit(1)
                        Text(PathUtilities.abbreviated(copy.parentPath))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    if group?.referenceFileId == copy.id {
                        Text("Reference").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Reveal") { model.reveal([copy.path]) }
                }
            }
            if let id = detail.file.id {
                Button(group?.referenceFileId == id ? "This Is the Copy to Keep" : "Keep This Copy, Review the Others") {
                    model.setPreferredCopy(id)
                }
                .disabled(group?.preferredFileId == id)
            }
        } header: {
            Text("Identical Copies (\(detail.duplicateCopies.count))")
        } footer: {
            Text("These files have byte-for-byte identical content (same SHA-256). Similar-looking files are never listed here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func relationshipsSection(_ detail: FileDetail) -> some View {
        Section("Related Items") {
            ForEach(detail.relationships) { relation in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(relation.kind.displayName)
                        Text(relation.isVerified ? "Verified" : "Inferred")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(PathUtilities.abbreviated(relation.otherPath))
                        .font(.caption)
                        .textSelection(.enabled)
                    Text(relation.evidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func historySection(_ detail: FileDetail) -> some View {
        Section("History") {
            ForEach(detail.actions) { action in
                LabeledContent {
                    Text(Format.date(action.performedAt))
                } label: {
                    Text(action.actionType.displayName + (action.detail.map { ": \($0)" } ?? ""))
                }
            }
        }
    }

    private func listItem(for detail: FileDetail) -> FileListItem? {
        guard let id = detail.file.id else { return nil }
        let file = detail.file
        return FileListItem(
            id: id, filename: file.filename, path: file.path, parentPath: file.parentPath,
            fileExtension: file.fileExtension, itemKind: file.itemKind, uti: file.uti, sizeBytes: file.sizeBytes,
            modifiedAt: file.modifiedAt, createdAt: file.createdAt, categoryId: file.categoryId,
            categoryName: detail.category?.name ?? "", reviewStatus: file.reviewStatus,
            availability: file.availability, cleanupPriority: file.cleanupPriority, topReason: nil,
            isDuplicate: detail.duplicateGroup != nil, rootName: detail.root?.displayName ?? ""
        )
    }
}
