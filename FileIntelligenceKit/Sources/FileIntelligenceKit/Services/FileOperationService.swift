import Foundation
import GRDB

/// The only service that changes files on disk: it moves them to the Trash or into an archive folder.
///
/// Files are moved, never deleted, so every action can be undone in Finder. Each item is logged in
/// `file_actions` with its destination. The index follows by rescanning `changedFolders`.
public struct FileOperationService: Sendable {
    let database: AppDatabase
    let scorer: CleanupScorer
    let preferences: PreferencesRepository

    public struct Outcome: Sendable, Equatable {
        public var succeeded = 0
        /// One "name: reason" line per item that was not moved.
        public var failures: [String] = []
        /// Folders whose contents changed. Rescan them so the index follows the moved items.
        public var changedFolders: Set<String> = []
    }

    public init(database: AppDatabase, scorer: CleanupScorer, preferences: PreferencesRepository) {
        self.database = database
        self.scorer = scorer
        self.preferences = preferences
    }

    /// Moves items to the Trash, where Finder's Put Back restores them.
    public func moveToTrash(fileIds: [Int64], now: Date = Date()) async throws -> Outcome {
        try await move(fileIds, action: .trash, status: .trashed, now: now) { url in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return (trashed as URL?)?.path
        }
    }

    /// Moves items into `folder`. An item with the same name already there is never replaced.
    public func archive(fileIds: [Int64], to folder: URL, now: Date = Date()) async throws -> Outcome {
        try await move(fileIds, action: .archive, status: .archived, now: now) { url in
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination.path
        }
    }

    private func move(
        _ fileIds: [Int64],
        action: FileActionType,
        status: ReviewStatus,
        now: Date,
        operation: (URL) throws -> String?
    ) async throws -> Outcome {
        guard !fileIds.isEmpty else { return Outcome() }
        let rows = try await database.reader.read { db -> [Row] in
            var rows: [Row] = []
            try SQL.forEachChunk(of: fileIds) { chunk, placeholders in
                rows += try Row.fetchAll(
                    db,
                    sql: "SELECT id, path, filename, availability FROM files WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
            return rows
        }

        let batchId = UUID().uuidString
        var outcome = Outcome()
        var records: [FileActionRecord] = []
        var movedIds: [Int64] = []
        for row in rows {
            let id: Int64 = row["id"]
            let path: String = row["path"]
            var record = FileActionRecord(
                id: nil, fileId: id, batchId: batchId, actionType: action, originalPath: path,
                destinationPath: nil, detail: nil, performedAt: now, result: .succeeded,
                errorDetails: nil, recoveryInfo: nil
            )
            do {
                guard (row["availability"] as String) == Availability.available.rawValue else {
                    throw FileIntelligenceError.invalidInput("The item is not available on disk.")
                }
                record.destinationPath = try operation(URL(fileURLWithPath: path))
                movedIds.append(id)
                outcome.succeeded += 1
                outcome.changedFolders.insert(PathUtilities.parent(of: path))
                if let destination = record.destinationPath {
                    outcome.changedFolders.insert(PathUtilities.parent(of: destination))
                }
            } catch {
                record.result = .failed
                record.errorDetails = error.localizedDescription
                outcome.failures.append("\(row["filename"] as String): \(error.localizedDescription)")
            }
            records.append(record)
        }

        try await database.writer.write { [movedIds, records] db in
            try SQL.forEachChunk(of: movedIds) { chunk, placeholders in
                var values: [(any DatabaseValueConvertible)?] = [status, now]
                values += chunk.map { $0 as (any DatabaseValueConvertible)? }
                try db.execute(
                    sql: "UPDATE files SET review_status = ?, reviewed_at = ? WHERE id IN (\(placeholders))",
                    arguments: SQL.arguments(values)
                )
            }
            for var record in records {
                try record.insert(db)
            }
        }
        try scorer.score(fileIds: movedIds, settings: preferences.loadSettings().scoring, now: now)
        return outcome
    }
}
