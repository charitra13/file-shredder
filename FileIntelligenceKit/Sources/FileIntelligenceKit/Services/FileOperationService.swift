import Foundation
import GRDB

/// The only service that changes files on disk: it moves them to the Trash.
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

    /// A post-move failure that preserves completed moves so the caller can still reconcile them.
    public struct CompletionError: Error, LocalizedError {
        public let outcome: Outcome
        public let underlyingError: any Error

        public var errorDescription: String? {
            "Items were moved to the Trash, but their activity or review information could not be updated. Rescan the location if its file list is out of date."
        }
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

    func move(
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
                    sql: """
                        SELECT id, path, filename, availability, item_kind, volume_uuid, inode,
                               size_bytes, modified_at, created_at
                        FROM files WHERE id IN (\(placeholders))
                        """,
                    arguments: StatementArguments(chunk)
                )
            }
            return rows
        }

        let batchId = UUID().uuidString
        var outcome = Outcome()
        var records: [FileActionRecord] = []
        var movedIds: [Int64] = []
        let volumes = VolumeIdentityResolver()
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
                // Packages and opaque folders store content-size estimates rather than lstat sizes.
                guard case .success(let info) = FileStat.read(path),
                      info.storedInode == (row["inode"] as Int64?),
                      volumes.identity(device: info.device, samplePath: PathUtilities.parent(of: path)) == (row["volume_uuid"] as String?),
                      DateUtilities.approximatelyEqual(info.createdAt, row["created_at"]),
                      DateUtilities.approximatelyEqual(info.modifiedAt, row["modified_at"]),
                      (row["item_kind"] as String) != ItemKind.regular.rawValue || info.size == (row["size_bytes"] as Int64)
                else {
                    throw FileIntelligenceError.invalidInput("The item changed since it was indexed. Rescan the location and confirm the move again.")
                }
                record.destinationPath = try operation(URL(fileURLWithPath: path))
                movedIds.append(id)
                outcome.succeeded += 1
                outcome.changedFolders.insert(PathUtilities.parent(of: path))
            } catch {
                record.result = .failed
                record.errorDetails = error.localizedDescription
                outcome.failures.append("\(row["filename"] as String): \(error.localizedDescription)")
            }
            records.append(record)
        }

        do {
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
        } catch {
            guard outcome.succeeded > 0 else { throw error }
            throw CompletionError(outcome: outcome, underlyingError: error)
        }
        return outcome
    }
}
