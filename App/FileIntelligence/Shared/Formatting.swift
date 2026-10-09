import AppKit
import FileIntelligenceKit
import SwiftUI
import UniformTypeIdentifiers

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(.relative(presentation: .named))
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: max(seconds, 1)) ?? "—"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func typeDescription(uti: String?, kind: ItemKind) -> String {
        if let uti, let type = UTType(uti), let description = type.localizedDescription {
            return description
        }
        return kind.displayName
    }
}

/// System icons for file types, cached by type identifier. Never reads file contents.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(uti: String?, kind: ItemKind) -> NSImage {
        let key = uti ?? "kind:\(kind.rawValue)"
        if let cached = cache[key] { return cached }
        let type: UTType
        if let uti, let resolved = UTType(uti) {
            type = resolved
        } else {
            switch kind {
            case .directory: type = .folder
            case .package: type = .package
            case .symlink: type = .symbolicLink
            default: type = .data
            }
        }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

struct FileIconView: View {
    let uti: String?
    let kind: ItemKind
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: FileIcons.icon(uti: uti, kind: kind))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PriorityBadge: View {
    let priority: Int?
    let status: ReviewStatus

    var body: some View {
        Group {
            if status.suppressesRecommendations {
                Text(status == .keep ? "Keep" : "Ignored")
                    .foregroundStyle(.secondary)
            } else if let priority, priority > 0 {
                Text("\(priority)")
                    .monospacedDigit()
                    .fontWeight(priority >= 50 ? .semibold : .regular)
                    .foregroundStyle(priority >= 50 ? Color.orange : Color.primary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if status.suppressesRecommendations { return status.displayName }
        if let priority, priority > 0 { return "Review priority \(priority)" }
        return "No suggestion"
    }
}

struct AvailabilityBadge: View {
    let availability: Availability

    var body: some View {
        if availability != .available {
            Text(availability.displayName)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
        }
    }
}

/// Explains, in one place, what the review priority means.
struct PriorityDisclaimer: View {
    var body: some View {
        Text("Priority orders files for your review. It is a heuristic, not a measure of how safe a file is to delete, and nothing is ever removed automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
