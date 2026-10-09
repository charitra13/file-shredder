import Foundation
import GRDB

/// Applies `ClassificationEngine` to pending files and persists results with their rationale.
///
/// Files classified by the user are never reclassified automatically.
public struct ClassificationService: Sendable {
    let database: AppDatabase
    let conformance: TypeConformance
    var pageSize = 1_000

    public init(database: AppDatabase, conformance: TypeConformance = .system) {
        self.database = database
        self.conformance = conformance
    }

    private struct PendingFile {
        let id: Int64
        let input: ClassificationInput
    }

    /// Classifies every file whose classification is missing or out of date. Returns the number processed.
    @discardableResult
    public func classifyPending(progress: @Sendable (ProcessingProgress) -> Void = { _ in }) async throws -> Int {
        let (categoryIds, engine) = try makeEngine()
        let total = try await database.reader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM files
                WHERE classified_at IS NULL AND item_kind != 'directory' AND classification_source != 'user'
                """) ?? 0
        }
        guard total > 0 else { return 0 }

        var processed = 0
        var lastId: Int64 = 0
        while true {
            try Task.checkCancellation()
            let afterId = lastId
            let page: [PendingFile] = try await database.reader.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, filename, file_extension, uti, item_kind, size_bytes, detected_signature, path, symlink_target
                    FROM files
                    WHERE classified_at IS NULL AND item_kind != 'directory' AND classification_source != 'user' AND id > ?
                    ORDER BY id
                    LIMIT ?
                    """, arguments: [afterId, pageSize])
                return rows.map { row -> PendingFile in
                    let signatureRaw: String? = row["detected_signature"]
                    let kindRaw: String = row["item_kind"]
                    return PendingFile(
                        id: row["id"],
                        input: ClassificationInput(
                            filename: row["filename"],
                            fileExtension: row["file_extension"],
                            uti: row["uti"],
                            itemKind: ItemKind(rawValue: kindRaw) ?? .other,
                            sizeBytes: row["size_bytes"],
                            signature: signatureRaw.flatMap(FormatSignature.init(rawValue:)),
                            path: row["path"],
                            symlinkTarget: row["symlink_target"]
                        )
                    )
                }
            }
            guard let last = page.last else { break }
            lastId = last.id

            let results = page.map { ($0.id, engine.classify($0.input)) }
            try write(results, categoryIds: categoryIds, now: Date())
            processed += page.count
            progress(ProcessingProgress(stage: .classification, completed: processed, total: total))
        }
        return processed
    }

    /// Marks all automatically classified files for reclassification (for example, after rules change).
    public func invalidateAutomaticClassifications() throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE files SET classified_at = NULL WHERE classification_source != 'user'")
        }
    }

    // MARK: - Helpers

    private func makeEngine() throws -> ([String: Int64], ClassificationEngine) {
        try database.reader.read { db in
            let categories = try FileCategory.fetchAll(db)
            var ids: [String: Int64] = [:]
            var bySlugId: [Int64: FileCategory] = [:]
            for category in categories {
                if let id = category.id {
                    ids[category.slug] = id
                    bySlugId[id] = category
                }
            }
            let rules = try CategoryRule.fetchAll(db, sql: """
                SELECT * FROM category_rules WHERE is_enabled = 1
                ORDER BY CASE origin WHEN 'manual' THEN 0 ELSE 1 END, priority DESC, id
                """)
            let resolved = rules.compactMap { rule -> ResolvedCategoryRule? in
                guard let category = bySlugId[rule.categoryId] else { return nil }
                return ResolvedCategoryRule(
                    matchKind: rule.matchKind,
                    pattern: rule.pattern,
                    categorySlug: category.slug,
                    categoryName: category.name,
                    origin: rule.origin
                )
            }
            return (ids, ClassificationEngine(rules: resolved, conformance: conformance))
        }
    }

    private func write(_ results: [(Int64, ClassificationResult?)], categoryIds: [String: Int64], now: Date) throws {
        try database.writer.write { db in
            let update = try db.cachedStatement(sql: """
                UPDATE files
                SET category_id = ?, classification_source = ?, classification_confidence = ?,
                    classification_explanation = ?, classified_at = ?, scored_at = NULL
                WHERE id = ? AND classification_source != 'user'
                """)
            let clearRuleTags = try db.cachedStatement(sql: "DELETE FROM file_tags WHERE file_id = ? AND source = 'rule'")
            let insertTag = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO file_tags (file_id, tag, source, created_at) VALUES (?, ?, 'rule', ?)
                """)
            let upsertLanguage = try db.cachedStatement(sql: """
                INSERT INTO file_metadata (file_id, source_language, extracted_at) VALUES (?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET source_language = excluded.source_language
                """)

            for (id, result) in results {
                guard let result else {
                    try update.execute(arguments: [nil as Int64?, ClassificationSource.none, nil as Double?, nil as String?, now, id])
                    continue
                }
                let categoryId = result.categorySlug.flatMap { categoryIds[$0] }
                try update.execute(arguments: [categoryId, result.source, result.confidence, result.explanation, now, id])
                try clearRuleTags.execute(arguments: [id])
                for tag in result.suggestedTags {
                    try insertTag.execute(arguments: [id, tag, now])
                }
                if let language = result.language {
                    try upsertLanguage.execute(arguments: [id, language, now])
                }
            }
        }
    }
}
