import AppKit
import FileIntelligenceKit
import SwiftUI

/// Context menu for one or more files. Every action changes only the index, except Reveal and Open.
struct FileContextMenu: View {
    let items: [FileListItem]
    let categories: [FileCategory]

    @Environment(AppModel.self) private var model

    private var ids: [Int64] { items.map(\.id) }

    var body: some View {
        if !items.isEmpty {
            Button("Reveal in Finder") { model.reveal(items.map(\.path)) }
            if items.count == 1, let item = items.first {
                Button("Open") { model.open(item.path) }
                    .disabled(!FileOpenPolicy.canOpen(item))
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Keep") { model.setReviewStatus(.keep, for: ids) }
            Button("Ignore Suggestion") { model.setReviewStatus(.ignored, for: ids) }
            Button("Review Later") { model.setReviewStatus(.reviewLater, for: ids) }
            Button("Clear Decision") { model.setReviewStatus(.unreviewed, for: ids) }
            Divider()
            CategoryMenu(title: "Set Category", categories: categories) { categoryId in
                model.reclassify(ids, categoryId: categoryId)
            }
            Button("Use Automatic Category") { model.resetClassification(ids) }
        }
    }
}

/// Opening applications or installers would run them, so those can only be revealed.
enum FileOpenPolicy {
    static func canOpen(_ item: FileListItem) -> Bool {
        guard item.availability == .available, item.itemKind == .regular || item.itemKind == .package else { return false }
        let blockedExtensions: Set<String> = ["app", "pkg", "mpkg", "dmg", "command", "tool", "sh", "exe", "msi", "jar"]
        if let ext = item.fileExtension, blockedExtensions.contains(ext) { return false }
        if let uti = item.uti, uti == "com.apple.application-bundle" || uti == "public.unix-executable" { return false }
        return true
    }
}

struct CategoryMenu: View {
    let title: String
    let categories: [FileCategory]
    let action: (Int64) -> Void

    private var topLevel: [FileCategory] { categories.filter { $0.parentId == nil } }

    var body: some View {
        Menu(title) {
            ForEach(topLevel) { category in
                let children = categories.filter { $0.parentId == category.id }
                if children.isEmpty {
                    Button(category.name) { if let id = category.id { action(id) } }
                } else {
                    Menu(category.name) {
                        Button(category.name) { if let id = category.id { action(id) } }
                        Divider()
                        ForEach(children) { child in
                            Button(child.name) { if let id = child.id { action(id) } }
                        }
                    }
                }
            }
        }
    }
}

/// Inspector content when several files are selected.
struct BulkSelectionView: View {
    let items: [FileListItem]
    let categories: [FileCategory]

    @Environment(AppModel.self) private var model

    private var ids: [Int64] { items.map(\.id) }
    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Selected", value: "\(items.count.formatted()) items")
                LabeledContent("Total size", value: Format.bytes(totalBytes))
                LabeledContent("With suggestions", value: items.filter { ($0.cleanupPriority ?? 0) > 0 }.count.formatted())
            }
            Section("Review Decision") {
                Button("Keep All") { model.setReviewStatus(.keep, for: ids) }
                Button("Ignore Suggestions for All") { model.setReviewStatus(.ignored, for: ids) }
                Button("Review All Later") { model.setReviewStatus(.reviewLater, for: ids) }
                Button("Clear Decisions") { model.setReviewStatus(.unreviewed, for: ids) }
            }
            Section("Classification") {
                CategoryMenu(title: "Set Category for All", categories: categories) { categoryId in
                    model.reclassify(ids, categoryId: categoryId)
                }
                Button("Use Automatic Categories") { model.resetClassification(ids) }
            }
            Section {
                Button("Reveal All in Finder") { model.reveal(items.map(\.path)) }
            } footer: {
                Text("Decisions are saved in the index and survive rescans. Files on disk are not changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
