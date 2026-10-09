import Foundation
import GRDB

public struct ActivityRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Recent scans, newest first. Event-driven change updates are hidden unless requested.
    public func recentRuns(limit: Int = 100, includeChangeUpdates: Bool = false) async throws -> [ScanRunSummary] {
        try await database.reader.read { db in
            let filter = includeChangeUpdates ? "" : "WHERE s.kind = 'full' OR s.state != 'completed' OR s.files_added + s.files_moved + s.files_missing > 0"
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, r.display_name AS root_name
                FROM scan_runs s JOIN scan_roots r ON r.id = s.root_id
                \(filter)
                ORDER BY s.started_at DESC, s.id DESC
                LIMIT ?
                """, arguments: [limit])
            return try rows.map { row in
                ScanRunSummary(run: try ScanRun(row: row), rootName: row["root_name"])
            }
        }
    }

    public func issues(runId: Int64, limit: Int = 500) async throws -> [ScanIssue] {
        try await database.reader.read { db in
            try ScanIssue.fetchAll(db, sql: """
                SELECT * FROM scan_issues WHERE scan_run_id = ? ORDER BY id LIMIT ?
                """, arguments: [runId, limit])
        }
    }

    public func recentActions(limit: Int = 200) async throws -> [FileActionRecord] {
        try await database.reader.read { db in
            try FileActionRecord.fetchAll(db, sql: """
                SELECT * FROM file_actions ORDER BY performed_at DESC, id DESC LIMIT ?
                """, arguments: [limit])
        }
    }
}
