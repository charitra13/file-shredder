import Darwin
import Foundation
import GRDB

/// Counters reported by one batch of observations.
public struct BatchResult: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var unchanged = 0
    public var moved = 0
    /// Folders that were new at their path. Shallow scans follow up with recursive scans of these.
    public var newDirectoryPaths: [String] = []
}

public struct FinalizeResult: Sendable, Equatable {
    public var missing = 0
    public var inaccessible = 0
    public var removedFromIndex = 0
}

/// Persists scan observations and reconciles them with the existing index.
///
/// Reconciliation rules:
/// - A known path is updated in place; derived data (hashes, classification) is invalidated only when the
///   metadata shows the content may have changed. Review decisions are always kept.
/// - A new path whose volume, inode, kind and creation date match an indexed record whose old path no longer
///   holds that inode is treated as a move or rename: the existing record (and its decisions) follows the file.
///   A matching inode at a path that still exists is a hard link and becomes its own record.
/// - After a complete pass, records in scope that were not seen are checked on disk: gone → missing,
///   unreadable → inaccessible, still present → out of scope (newly excluded) → removed from the index.
///   Records are never deleted just because a scan could not see them.
public struct IndexWriter: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Runs

    public func beginRun(rootId: Int64, scope: ScanScope, now: Date) throws -> Int64 {
        try database.writer.write { db in
            var run = ScanRun(
                id: nil, rootId: rootId, kind: scope.kind, scopePath: scope.startPath, startedAt: now,
                finishedAt: nil, state: .running, itemsSeen: 0, directoriesVisited: 0, filesAdded: 0,
                filesUpdated: 0, filesMoved: 0, filesMissing: 0, filesInaccessible: 0,
                filesRemovedFromIndex: 0, issuesCount: 0, lastError: nil
            )
            try run.insert(db)
            if scope.kind == .full {
                try db.execute(
                    sql: "UPDATE scan_roots SET scan_state = ?, last_scan_started_at = ?, last_error = NULL WHERE id = ?",
                    arguments: [RootScanState.scanning, now, rootId]
                )
            } else {
                try db.execute(
                    sql: "UPDATE scan_roots SET scan_state = ? WHERE id = ?",
                    arguments: [RootScanState.scanning, rootId]
                )
            }
            return run.id ?? 0
        }
    }

    /// Records a run that ended early. Items are left untouched; nothing is marked missing.
    public func endRun(runId: Int64, rootId: Int64, state: ScanRunState, message: String?, totals: ScanOutcome, now: Date) throws {
        try database.writer.write { db in
            try updateRunTotals(db, runId: runId, totals: totals)
            try db.execute(
                sql: "UPDATE scan_runs SET state = ?, finished_at = ?, last_error = ? WHERE id = ?",
                arguments: [state, now, message, runId]
            )
            let rootState: RootScanState = state == .failed ? .failed : .interrupted
            try db.execute(
                sql: "UPDATE scan_roots SET scan_state = ?, last_error = ? WHERE id = ?",
                arguments: [rootState, message, rootId]
            )
        }
    }

    /// The location itself is unreachable (for example, a disconnected drive). Its items are kept and
    /// marked unavailable rather than missing, so reconnecting restores them with all decisions intact.
    public func markRootUnavailable(rootId: Int64, message: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE files SET availability = ? WHERE root_id = ? AND availability = ?",
                arguments: [Availability.unavailable, rootId, Availability.available]
            )
            try db.execute(
                sql: "UPDATE scan_roots SET scan_state = ?, last_error = ? WHERE id = ?",
                arguments: [RootScanState.unavailable, message, rootId]
            )
        }
    }

    public func recordIssues(_ issues: [ScanIssueInfo], runId: Int64, now: Date = Date()) throws {
        guard !issues.isEmpty else { return }
        try database.writer.write { db in
            let existing = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_issues WHERE scan_run_id = ?", arguments: [runId]) ?? 0
            // Keep the log bounded; the run's issue count still reflects every problem.
            let capacity = max(0, 1_000 - existing)
            for issue in issues.prefix(capacity) {
                var record = ScanIssue(id: nil, scanRunId: runId, path: issue.path, message: issue.message, createdAt: now)
                try record.insert(db)
            }
        }
    }

    // MARK: - Observations

    public func apply(_ observations: [FileObservation], rootId: Int64, runId: Int64, now: Date) throws -> BatchResult {
        try database.writer.write { db in
            var result = BatchResult()
            let byPath = try db.cachedStatement(sql: "SELECT * FROM files WHERE path = ?")
            let touch = try db.cachedStatement(sql: """
                UPDATE files
                SET root_id = ?, last_seen_at = ?, last_seen_scan_id = ?, availability = 'available', missing_since = NULL
                WHERE id = ?
                """)

            for observation in observations {
                if var existing = try FileRecord.fetchOne(byPath, arguments: [observation.path]) {
                    if existing.contentMayDiffer(from: observation) {
                        existing.absorb(observation, rootId: rootId, runId: runId, now: now, contentChanged: true)
                        try existing.update(db)
                        result.updated += 1
                    } else {
                        try touch.execute(arguments: [rootId, now, runId, existing.id])
                        result.unchanged += 1
                    }
                } else if var moved = try Self.findMovedRecord(db, for: observation) {
                    let contentChanged = moved.sizeBytes != observation.sizeBytes
                        || !DateUtilities.approximatelyEqual(moved.modifiedAt, observation.modifiedAt)
                    moved.absorb(observation, rootId: rootId, runId: runId, now: now, contentChanged: contentChanged)
                    try moved.update(db)
                    result.moved += 1
                    if observation.itemKind == .directory {
                        result.newDirectoryPaths.append(observation.path)
                    }
                } else {
                    var record = FileRecord(observation: observation, rootId: rootId, runId: runId, now: now)
                    try record.insert(db)
                    result.added += 1
                    if observation.itemKind == .directory {
                        result.newDirectoryPaths.append(observation.path)
                    }
                }
            }
            return result
        }
    }

    static func findMovedRecord(_ db: Database, for observation: FileObservation) throws -> FileRecord? {
        guard let inode = observation.inode, let volume = observation.volumeUUID else { return nil }
        let candidates = try FileRecord.fetchAll(
            db,
            sql: "SELECT * FROM files WHERE volume_uuid = ? AND inode = ? AND item_kind = ? AND path != ?",
            arguments: [volume, inode, observation.itemKind, observation.path]
        )
        for candidate in candidates {
            // Creation dates survive renames and same-volume moves; a mismatch means inode reuse.
            if let stored = candidate.createdAt, let observed = observation.createdAt,
               !DateUtilities.approximatelyEqual(stored, observed) {
                continue
            }
            switch FileStat.read(candidate.path) {
            case .success(let info) where info.storedInode == inode:
                continue // The old path still holds this inode: a hard link, not a move.
            default:
                return candidate
            }
        }
        return nil
    }

    // MARK: - Finalisation

    /// Completes a scan that traversed its whole scope, reconciling records that were not seen.
    public func finalize(
        runId: Int64,
        rootId: Int64,
        scope: ScanScope,
        skippedSubtrees: Set<String>,
        totals: ScanOutcome,
        now: Date
    ) throws -> FinalizeResult {
        try database.writer.write { db in
            var sql = """
                SELECT id, path, item_kind FROM files
                WHERE root_id = ? AND (last_seen_scan_id IS NULL OR last_seen_scan_id != ?) AND availability != 'missing'
                """
            var values: [(any DatabaseValueConvertible)?] = [rootId, runId]
            switch scope.kind {
            case .full:
                break
            case .subtree:
                let range = SQL.descendantRange(of: scope.startPath)
                sql += " AND path >= ? AND path < ?"
                values += [range.lower, range.upper]
            case .shallow:
                sql += " AND parent_path = ?"
                values.append(scope.startPath)
            }
            let unseen = try Row.fetchAll(db, sql: sql, arguments: SQL.arguments(values))

            var missing: [Int64] = []
            var missingDirectories: [String] = []
            var inaccessible: [Int64] = []
            var outOfScope: [Int64] = []
            for row in unseen {
                let id: Int64 = row["id"]
                let path: String = row["path"]
                if skippedSubtrees.contains(where: { PathUtilities.isPath(path, strictlyInside: $0) }) {
                    continue // Owned by a nested location; its own scan reconciles it.
                }
                switch FileStat.read(path) {
                case .failure(let error) where error.code == ENOENT || error.code == ENOTDIR:
                    missing.append(id)
                    if (row["item_kind"] as String) == ItemKind.directory.rawValue {
                        missingDirectories.append(path)
                    }
                case .failure:
                    inaccessible.append(id)
                case .success:
                    outOfScope.append(id)
                }
            }

            var result = FinalizeResult()
            try SQL.forEachChunk(of: missing) { chunk, placeholders in
                var chunkValues: [(any DatabaseValueConvertible)?] = [now]
                chunkValues += chunk.map { $0 as (any DatabaseValueConvertible)? }
                try db.execute(
                    sql: "UPDATE files SET availability = 'missing', missing_since = COALESCE(missing_since, ?) WHERE id IN (\(placeholders))",
                    arguments: SQL.arguments(chunkValues)
                )
            }
            result.missing = missing.count
            // Everything beneath a vanished folder is gone too, even if a shallow scan never looked inside.
            for directory in missingDirectories {
                let range = SQL.descendantRange(of: directory)
                try db.execute(
                    sql: """
                    UPDATE files SET availability = 'missing', missing_since = COALESCE(missing_since, ?)
                    WHERE root_id = ? AND path >= ? AND path < ? AND availability != 'missing'
                    """,
                    arguments: [now, rootId, range.lower, range.upper]
                )
                result.missing += db.changesCount
            }
            try SQL.forEachChunk(of: inaccessible) { chunk, placeholders in
                try db.execute(
                    sql: "UPDATE files SET availability = 'inaccessible' WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
            result.inaccessible = inaccessible.count
            try SQL.forEachChunk(of: outOfScope) { chunk, placeholders in
                try db.execute(sql: "DELETE FROM files WHERE id IN (\(placeholders))", arguments: StatementArguments(chunk))
            }
            result.removedFromIndex = outOfScope.count

            var finalTotals = totals
            finalTotals.missing = result.missing
            finalTotals.inaccessible = result.inaccessible
            finalTotals.removedFromIndex = result.removedFromIndex
            try updateRunTotals(db, runId: runId, totals: finalTotals)
            try db.execute(
                sql: "UPDATE scan_runs SET state = ?, finished_at = ? WHERE id = ?",
                arguments: [ScanRunState.completed, now, runId]
            )
            if scope.kind == .full {
                try db.execute(
                    sql: "UPDATE scan_roots SET scan_state = ?, last_successful_scan_at = ?, last_error = NULL WHERE id = ?",
                    arguments: [RootScanState.idle, now, rootId]
                )
            } else {
                try db.execute(
                    sql: "UPDATE scan_roots SET scan_state = ? WHERE id = ?",
                    arguments: [RootScanState.idle, rootId]
                )
            }
            return result
        }
    }

    private func updateRunTotals(_ db: Database, runId: Int64, totals: ScanOutcome) throws {
        try db.execute(
            sql: """
            UPDATE scan_runs SET items_seen = ?, directories_visited = ?, files_added = ?, files_updated = ?,
                files_moved = ?, files_missing = ?, files_inaccessible = ?, files_removed_from_index = ?, issues_count = ?
            WHERE id = ?
            """,
            arguments: [
                totals.itemsSeen, totals.directoriesVisited, totals.added, totals.updated, totals.moved,
                totals.missing, totals.inaccessible, totals.removedFromIndex, totals.issues, runId,
            ]
        )
    }
}
