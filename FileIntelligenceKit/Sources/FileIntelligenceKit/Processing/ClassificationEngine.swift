import Foundation
import UniformTypeIdentifiers

public struct ClassificationInput: Sendable, Equatable {
    public var filename: String
    public var fileExtension: String?
    public var uti: String?
    public var itemKind: ItemKind
    public var sizeBytes: Int64
    public var signature: FormatSignature?
    public var path: String
    public var symlinkTarget: String?

    public init(
        filename: String,
        fileExtension: String?,
        uti: String?,
        itemKind: ItemKind,
        sizeBytes: Int64,
        signature: FormatSignature?,
        path: String,
        symlinkTarget: String? = nil
    ) {
        self.filename = filename
        self.fileExtension = fileExtension
        self.uti = uti
        self.itemKind = itemKind
        self.sizeBytes = sizeBytes
        self.signature = signature
        self.path = path
        self.symlinkTarget = symlinkTarget
    }
}

public struct ClassificationResult: Sendable, Equatable {
    /// `nil` when a category does not apply (for example, symbolic links).
    public var categorySlug: String?
    public var source: ClassificationSource
    public var confidence: Double
    public var explanation: String
    /// Suggested tags from filename keywords. Never used to assign a category on their own.
    public var suggestedTags: [String]
    public var language: String?

    public init(
        categorySlug: String?,
        source: ClassificationSource,
        confidence: Double,
        explanation: String,
        suggestedTags: [String] = [],
        language: String? = nil
    ) {
        self.categorySlug = categorySlug
        self.source = source
        self.confidence = confidence
        self.explanation = explanation
        self.suggestedTags = suggestedTags
        self.language = language
    }
}

/// A user or learned rule resolved to a category slug, ready for the engine.
public struct ResolvedCategoryRule: Sendable, Equatable {
    public var matchKind: RuleMatchKind
    public var pattern: String
    public var categorySlug: String
    public var categoryName: String
    public var origin: RuleOrigin

    public init(matchKind: RuleMatchKind, pattern: String, categorySlug: String, categoryName: String, origin: RuleOrigin) {
        self.matchKind = matchKind
        self.pattern = pattern
        self.categorySlug = categorySlug
        self.categoryName = categoryName
        self.origin = origin
    }

    func matches(_ input: ClassificationInput) -> Bool {
        let pattern = self.pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        switch matchKind {
        case .fileExtension:
            let normalized = pattern.hasPrefix(".") ? String(pattern.dropFirst()) : pattern
            return input.fileExtension == normalized.lowercased()
        case .filenameContains:
            return input.filename.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .pathPrefix:
            return PathUtilities.isPath(input.path, inside: PathUtilities.normalized(pattern))
        }
    }
}

/// Answers "does type A conform to type B". Injectable so tests can run deterministically.
public struct TypeConformance: Sendable {
    let check: @Sendable (_ uti: String, _ parent: String) -> Bool

    public init(_ check: @escaping @Sendable (_ uti: String, _ parent: String) -> Bool) {
        self.check = check
    }

    public static let system = TypeConformance { uti, parent in
        guard let type = UTType(uti), let parentType = UTType(parent) else { return false }
        return type.conforms(to: parentType)
    }

    func conforms(_ uti: String?, to parent: String) -> Bool {
        guard let uti else { return false }
        return uti == parent || check(uti, parent)
    }
}

/// Layered, deterministic, offline classifier. Every result carries its rationale.
///
/// Order: your rules → links → packages → temporary patterns → extension table →
/// system type conformance → well-known filenames → content signature → Unknown.
/// When an extension's expected signature contradicts the content, the content wins with lower confidence.
public struct ClassificationEngine: Sendable {
    public var rules: [ResolvedCategoryRule]
    public var conformance: TypeConformance
    /// Results below this confidence are recorded as Unknown, with the tentative match in the rationale.
    public var minimumConfidence: Double

    public init(rules: [ResolvedCategoryRule] = [], conformance: TypeConformance = .system, minimumConfidence: Double = 0.5) {
        self.rules = rules
        self.conformance = conformance
        self.minimumConfidence = minimumConfidence
    }

    /// Returns nil for folders, which are not classified.
    public func classify(_ input: ClassificationInput) -> ClassificationResult? {
        if input.itemKind == .directory { return nil }

        if let rule = rules.first(where: { $0.matches(input) }) {
            let source: ClassificationSource = rule.origin == .learned ? .learnedRule : .userRule
            let explanation = rule.origin == .learned
                ? "Learned from your corrections: \(rule.matchKind.displayName.lowercased()) “\(rule.pattern)” → \(rule.categoryName)."
                : "Matched your rule: \(rule.matchKind.displayName.lowercased()) “\(rule.pattern)” → \(rule.categoryName)."
            return finish(ClassificationResult(categorySlug: rule.categorySlug, source: source, confidence: 0.95, explanation: explanation), input)
        }

        if input.itemKind == .symlink {
            let target = input.symlinkTarget.map { " pointing to “\($0)”" } ?? ""
            return ClassificationResult(
                categorySlug: nil,
                source: .builtInRule,
                confidence: 1,
                explanation: "Symbolic link\(target). Links are recorded but never followed."
            )
        }

        if input.itemKind == .other {
            return ClassificationResult(
                categorySlug: "unknown",
                source: .builtInRule,
                confidence: 1,
                explanation: "Special filesystem item (socket, pipe or device). Its contents are never read."
            )
        }

        let ext = input.fileExtension?.lowercased()

        if input.itemKind == .package {
            if ext == "app" || conformance.conforms(input.uti, to: "com.apple.application-bundle") {
                return builtIn("applications", 0.95, "Application bundle (.app).", input)
            }
            if let ext, let entry = ClassificationTables.extensions[ext] {
                return builtIn(entry.slug, entry.confidence, "Package with the .\(ext) extension, a \(entry.label).", input)
            }
            return builtIn("unknown", 0.3, "Package bundle of an unrecognised type\(ext.map { " (.\($0))" } ?? "").", input)
        }

        if let reason = ClassificationTables.temporaryReason(filename: input.filename, fileExtension: ext) {
            return builtIn("temporary", 0.9, reason, input)
        }

        var tentative: ClassificationResult?
        if let ext, let entry = ClassificationTables.extensions[ext] {
            tentative = ClassificationResult(
                categorySlug: entry.slug, source: .builtInRule, confidence: entry.confidence,
                explanation: "The .\(ext) extension identifies a \(entry.label)."
            )
            if ext == "json" {
                tentative = jsonResult(size: input.sizeBytes)
            }
        } else if ext == "json" {
            tentative = jsonResult(size: input.sizeBytes)
        } else if let uti = input.uti,
                  let rule = ClassificationTables.conformance.first(where: { conformance.conforms(uti, to: $0.uti) }) {
            tentative = ClassificationResult(
                categorySlug: rule.entry.slug, source: .builtInRule, confidence: rule.entry.confidence,
                explanation: "Its system type (\(uti)) is a kind of \(rule.entry.label)."
            )
        } else if let entry = ClassificationTables.filenames[input.filename.lowercased()] {
            tentative = ClassificationResult(
                categorySlug: entry.slug, source: .builtInRule, confidence: entry.confidence,
                explanation: "“\(input.filename)” is a well-known \(entry.label) name."
            )
        } else if let signature = input.signature, let entry = ClassificationTables.signatures[signature] {
            let reason = ext == nil ? "It has no extension, but its" : "Its extension is not recognised, but its"
            return builtIn(entry.slug, entry.confidence, "\(reason) contents begin with a \(signature.displayName) signature.", input)
        } else if input.signature == .plainText {
            return builtIn("documents", 0.55, "Unrecognised type, but the contents look like plain text.", input)
        }

        if var result = tentative {
            if let ext,
               let signature = input.signature,
               let expected = ClassificationTables.expectedSignatures[ext],
               !expected.contains(signature) {
                if let entry = ClassificationTables.signatures[signature] {
                    return builtIn(
                        entry.slug,
                        min(entry.confidence, 0.6),
                        "The .\(ext) extension suggests a different format, but the contents begin with a \(signature.displayName) signature, so it was classified by its contents.",
                        input
                    )
                }
                result.confidence = 0.4
                result.explanation += " However, its contents do not match the .\(ext) format (\(signature.displayName)), so it needs review."
            }
            return finish(result, input)
        }

        let detail: String
        if let ext {
            detail = "No rule recognises the .\(ext) extension"
        } else {
            detail = "It has no extension"
        }
        let typeNote = input.signature.map { " and its contents are \($0.displayName)" } ?? ""
        return ClassificationResult(
            categorySlug: "unknown", source: .builtInRule, confidence: 0,
            explanation: "\(detail)\(typeNote)."
        )
    }

    private func jsonResult(size: Int64) -> ClassificationResult {
        if size >= 5 * 1_024 * 1_024 {
            return ClassificationResult(
                categorySlug: "datasets", source: .builtInRule, confidence: 0.65,
                explanation: "A large JSON file (over 5 MB) is most likely data rather than configuration."
            )
        }
        return ClassificationResult(
            categorySlug: "configuration", source: .builtInRule, confidence: 0.6,
            explanation: "JSON files are usually configuration or small data files."
        )
    }

    private func builtIn(_ slug: String, _ confidence: Double, _ explanation: String, _ input: ClassificationInput) -> ClassificationResult {
        finish(ClassificationResult(categorySlug: slug, source: .builtInRule, confidence: confidence, explanation: explanation), input)
    }

    /// Applies the low-confidence policy and adds language and tag suggestions.
    private func finish(_ result: ClassificationResult, _ input: ClassificationInput) -> ClassificationResult {
        var result = result
        if result.source == .builtInRule, result.categorySlug != nil, result.categorySlug != "unknown",
           result.confidence < minimumConfidence {
            result.explanation = "Low confidence, so left unclassified for review. " + result.explanation
            result.categorySlug = "unknown"
        }
        if result.categorySlug == "source-code", let ext = input.fileExtension?.lowercased() {
            result.language = ClassificationTables.sourceLanguages[ext]
        }
        if ["documents", "spreadsheets", "presentations"].contains(result.categorySlug ?? "") {
            let tags = Set(ClassificationTables.words(in: input.filename).compactMap { ClassificationTables.semanticKeywords[$0] })
            result.suggestedTags = tags.sorted()
        }
        return result
    }
}
