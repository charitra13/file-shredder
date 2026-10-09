import Foundation
import GRDB

/// Index maintenance. These operations only change the index, never files on disk.
public struct MaintenanceService: Sendable {
    let database: AppDatabase
    let classifier: ClassificationService

    public init(database: AppDatabase, classifier: ClassificationService) {
        self.database = database
        self.classifier = classifier
    }

    /// Forgets records of files that disappeared. Their review history in the activity log is kept.
    @discardableResult
    public func removeMissingFromIndex() async throws -> Int {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM files WHERE availability = 'missing'")
            return db.changesCount
        }
    }

    /// Recomputes every automatic classification on the next processing pass. Your own choices are kept.
    public func reclassifyAutomaticCategories() throws {
        try classifier.invalidateAutomaticClassifications()
    }

    /// Clears stored hashes so duplicates are verified again from disk on the next processing pass.
    public func resetDuplicateDetection() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE files SET quick_hash = NULL, content_hash = NULL, hashed_at = NULL")
            try db.execute(sql: "DELETE FROM duplicate_groups")
        }
    }

    /// Deletes learned rules and lets affected files be reclassified. Manual rules and your choices are kept.
    @discardableResult
    public func resetLearnedPreferences() async throws -> Int {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM category_rules WHERE origin = 'learned'")
            let removed = db.changesCount
            try db.execute(sql: "UPDATE files SET classified_at = NULL WHERE classification_source = 'learnedRule'")
            return removed
        }
    }

    /// Reports the result of SQLite's integrity check ("ok" when healthy).
    public func integrityCheck() async throws -> String {
        try await database.reader.read { db in
            try String.fetchAll(db, sql: "PRAGMA integrity_check").joined(separator: "\n")
        }
    }

    /// Rebuilds the database file to reclaim space after large deletions.
    public func compact() async throws {
        try await database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }
}
