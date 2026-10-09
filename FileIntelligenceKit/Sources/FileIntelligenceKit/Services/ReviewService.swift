import Foundation
import GRDB

/// Records the user's review decisions and corrections. Nothing here touches files on disk.
///
/// Every decision is logged in `file_actions`, survives rescans (it lives on the file's stable record),
/// and immediately updates the affected review priorities.
public struct ReviewService: Sendable {
    let database: AppDatabase
    let scorer: CleanupScorer
    let preferences: PreferencesRepository
    /// Corrections needed before a consistent pattern becomes a learned rule.
    var learningThreshold = 3

    public init(database: AppDatabase, scorer: CleanupScorer, preferences: PreferencesRepository) {
        self.database = database
        self.scorer = scorer
        self.preferences = preferences
    }

    public func setReviewStatus(_ status: ReviewStatus, fileIds: [Int64], now: Date = Date()) async throws {
        guard !fileIds.isEmpty else { return }
        let action: FileActionType
        switch status {
        case .keep: action = .keep
        case .ignored: action = .ignore
        case .reviewLater: action = .reviewLater
        case .unreviewed: action = .reopen
        case .archived, .trashed:
            throw FileIntelligenceError.invalidInput("Archive and Trash are file operations, not review decisions.")
        }
        let batchId = UUID().uuidString
        try await database.writer.write { db in
            try SQL.forEachChunk(of: fileIds) { chunk, placeholders in
                let paths = try Row.fetchAll(
                    db,
                    sql: "SELECT id, path FROM files WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                let reviewedAt: Date? = status == .unreviewed ? nil : now
                var values: [(any DatabaseValueConvertible)?] = [status, reviewedAt]
                values += chunk.map { $0 as (any DatabaseValueConvertible)? }
                try db.execute(
                    sql: "UPDATE files SET review_status = ?, reviewed_at = ? WHERE id IN (\(placeholders))",
                    arguments: SQL.arguments(values)
                )
                for row in paths {
                    try Self.log(db, fileId: row["id"], path: row["path"], action: action, detail: nil, batchId: batchId, now: now)
                }
            }
        }
        try scorer.score(fileIds: fileIds, settings: preferences.loadSettings().scoring, now: now)
    }

    /// Sets the category explicitly. User classifications are never overwritten by automatic rules.
    ///
    /// When the user has given the same extension the same category at least `learningThreshold` times
    /// (and never a different one), a transparent learned rule is created so similar files follow.
    public func reclassify(fileIds: [Int64], categoryId: Int64, now: Date = Date()) async throws {
        guard !fileIds.isEmpty else { return }
        let batchId = UUID().uuidString
        let threshold = learningThreshold
        try await database.writer.write { db in
            guard let category = try FileCategory.fetchOne(db, key: categoryId) else {
                throw FileIntelligenceError.categoryNotFound(categoryId)
            }
            var extensions = Set<String>()
            try SQL.forEachChunk(of: fileIds) { chunk, placeholders in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, path, file_extension FROM files WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                var values: [(any DatabaseValueConvertible)?] = [
                    categoryId, ClassificationSource.user, 1.0, "Set by you to \(category.name).", now,
                ]
                values += chunk.map { $0 as (any DatabaseValueConvertible)? }
                try db.execute(
                    sql: """
                    UPDATE files SET category_id = ?, classification_source = ?, classification_confidence = ?,
                        classification_explanation = ?, classified_at = ?
                    WHERE id IN (\(placeholders))
                    """,
                    arguments: SQL.arguments(values)
                )
                for row in rows {
                    try Self.log(db, fileId: row["id"], path: row["path"], action: .reclassify, detail: category.name, batchId: batchId, now: now)
                    if let ext: String = row["file_extension"] {
                        extensions.insert(ext)
                    }
                }
            }
            for ext in extensions {
                try Self.updateLearnedRule(db, fileExtension: ext, threshold: threshold, now: now)
            }
        }
        try scorer.score(fileIds: fileIds, settings: preferences.loadSettings().scoring, now: now)
    }

    /// Hands files back to automatic classification.
    public func resetClassification(fileIds: [Int64], now: Date = Date()) async throws {
        guard !fileIds.isEmpty else { return }
        let batchId = UUID().uuidString
        try await database.writer.write { db in
            try SQL.forEachChunk(of: fileIds) { chunk, placeholders in
                let rows = try Row.fetchAll(db, sql: "SELECT id, path FROM files WHERE id IN (\(placeholders))", arguments: StatementArguments(chunk))
                try db.execute(
                    sql: "UPDATE files SET classification_source = 'none', classified_at = NULL WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    try Self.log(db, fileId: row["id"], path: row["path"], action: .resetClassification, detail: nil, batchId: batchId, now: now)
                }
            }
        }
    }

    /// Chooses which copy of a duplicate group is the one to keep. Other copies become review candidates.
    public func setPreferredCopy(fileId: Int64, now: Date = Date()) async throws {
        let affected: [Int64] = try await database.writer.write { db -> [Int64] in
            guard let file = try FileRecord.fetchOne(db, key: fileId), let hash = file.contentHash else {
                throw FileIntelligenceError.fileNotFound(fileId)
            }
            try db.execute(
                sql: "UPDATE duplicate_groups SET preferred_file_id = ?, reference_file_id = ?, updated_at = ? WHERE content_hash = ?",
                arguments: [fileId, fileId, now, hash]
            )
            try Self.log(db, fileId: fileId, path: file.path, action: .setPreferredCopy, detail: nil, batchId: nil, now: now)
            return try Int64.fetchAll(db, sql: "SELECT id FROM files WHERE content_hash = ?", arguments: [hash])
        }
        try scorer.score(fileIds: affected, settings: preferences.loadSettings().scoring, now: now)
    }

    public func addTag(_ tag: String, fileIds: [Int64], now: Date = Date()) async throws {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !fileIds.isEmpty else { return }
        try await database.writer.write { db in
            for id in fileIds {
                guard let path = try String.fetchOne(db, sql: "SELECT path FROM files WHERE id = ?", arguments: [id]) else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO file_tags (file_id, tag, source, created_at) VALUES (?, ?, 'user', ?)
                    ON CONFLICT(file_id, tag) DO UPDATE SET source = 'user'
                    """,
                    arguments: [id, trimmed, now]
                )
                try Self.log(db, fileId: id, path: path, action: .addTag, detail: trimmed, batchId: nil, now: now)
            }
        }
    }

    public func removeTag(_ tag: String, fileIds: [Int64], now: Date = Date()) async throws {
        guard !fileIds.isEmpty else { return }
        try await database.writer.write { db in
            for id in fileIds {
                guard let path = try String.fetchOne(db, sql: "SELECT path FROM files WHERE id = ?", arguments: [id]) else { continue }
                try db.execute(sql: "DELETE FROM file_tags WHERE file_id = ? AND tag = ?", arguments: [id, tag])
                try Self.log(db, fileId: id, path: path, action: .removeTag, detail: tag, batchId: nil, now: now)
            }
        }
    }

    // MARK: - Helpers

    static func log(
        _ db: Database,
        fileId: Int64,
        path: String,
        action: FileActionType,
        detail: String?,
        batchId: String?,
        now: Date
    ) throws {
        var record = FileActionRecord(
            id: nil, fileId: fileId, batchId: batchId, actionType: action, originalPath: path,
            destinationPath: nil, detail: detail, performedAt: now, result: .succeeded,
            errorDetails: nil, recoveryInfo: nil
        )
        try record.insert(db)
    }

    static func updateLearnedRule(_ db: Database, fileExtension ext: String, threshold: Int, now: Date) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT category_id, COUNT(*) AS corrections FROM files
            WHERE classification_source = 'user' AND file_extension = ? AND category_id IS NOT NULL
            GROUP BY category_id
            """, arguments: [ext])
        try db.execute(
            sql: "DELETE FROM category_rules WHERE origin = 'learned' AND match_kind = 'fileExtension' AND pattern = ?",
            arguments: [ext]
        )
        guard rows.count == 1, let row = rows.first else { return }
        let corrections: Int = row["corrections"]
        guard corrections >= threshold else { return }
        var rule = CategoryRule(
            id: nil, matchKind: .fileExtension, pattern: ext, categoryId: row["category_id"], priority: 0,
            isEnabled: true, origin: .learned, note: "Learned from \(corrections) of your corrections.", createdAt: now
        )
        try rule.insert(db)
        try db.execute(
            sql: "UPDATE files SET classified_at = NULL WHERE classification_source != 'user' AND file_extension = ?",
            arguments: [ext]
        )
    }
}
