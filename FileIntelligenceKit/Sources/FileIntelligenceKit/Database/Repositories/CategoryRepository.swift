import Foundation
import GRDB

public struct CategoryRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func all() async throws -> [FileCategory] {
        try await database.reader.read { db in
            try FileCategory.fetchAll(db, sql: "SELECT * FROM categories ORDER BY sort_order, name COLLATE NOCASE")
        }
    }

    /// Categories with the number and size of available items assigned to each.
    public func stats() async throws -> [CategoryStat] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*, COUNT(f.id) AS file_count, COALESCE(SUM(f.size_bytes), 0) AS total_bytes
                FROM categories c
                LEFT JOIN files f ON f.category_id = c.id AND f.availability = 'available'
                GROUP BY c.id
                ORDER BY c.sort_order, c.name COLLATE NOCASE
                """)
            return try rows.map { row in
                CategoryStat(category: try FileCategory(row: row), fileCount: row["file_count"], totalBytes: row["total_bytes"])
            }
        }
    }

    public func rules() async throws -> [CategoryRuleSummary] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.*, c.name AS category_name FROM category_rules r
                JOIN categories c ON c.id = r.category_id
                ORDER BY r.origin, r.priority DESC, r.id
                """)
            return try rows.map { row in
                CategoryRuleSummary(rule: try CategoryRule(row: row), categoryName: row["category_name"])
            }
        }
    }

    /// Adds a transparent rule. All automatic classifications are recomputed on the next processing pass.
    public func addRule(matchKind: RuleMatchKind, pattern: String, categoryId: Int64) async throws {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileIntelligenceError.invalidInput("A rule needs a pattern.")
        }
        try await database.writer.write { db in
            var rule = CategoryRule(
                id: nil, matchKind: matchKind, pattern: trimmed, categoryId: categoryId, priority: 0,
                isEnabled: true, origin: .manual, note: nil, createdAt: Date()
            )
            try rule.insert(db)
            try db.execute(sql: "UPDATE files SET classified_at = NULL WHERE classification_source != 'user'")
        }
    }

    public func setRuleEnabled(_ enabled: Bool, ruleId: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE category_rules SET is_enabled = ? WHERE id = ?", arguments: [enabled, ruleId])
            try db.execute(sql: "UPDATE files SET classified_at = NULL WHERE classification_source != 'user'")
        }
    }

    public func deleteRule(ruleId: Int64) async throws {
        try await database.writer.write { db in
            _ = try CategoryRule.deleteOne(db, key: ruleId)
            try db.execute(sql: "UPDATE files SET classified_at = NULL WHERE classification_source != 'user'")
        }
    }
}
