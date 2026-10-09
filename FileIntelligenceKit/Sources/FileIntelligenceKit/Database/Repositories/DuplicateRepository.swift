import Foundation
import GRDB

public struct DuplicateRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func overview() async throws -> DuplicateOverview {
        try await database.reader.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS group_count, COALESCE(SUM(file_count), 0) AS files, COALESCE(SUM(reclaimable_bytes), 0) AS bytes
                FROM duplicate_groups
                """)
            return DuplicateOverview(
                groupCount: row.int("group_count"),
                fileCount: row.int("files"),
                reclaimableBytes: row.int64("bytes")
            )
        }
    }

    /// Groups ordered by recoverable storage, largest first.
    public func groups(offset: Int, limit: Int, text: String = "") async throws -> [DuplicateGroupSummary] {
        try await database.reader.read { db in
            var sql = """
                SELECT g.id, g.content_hash, g.size_bytes, g.file_count, g.reclaimable_bytes,
                       g.reference_file_id, g.preferred_file_id,
                       COALESCE(r.filename, '') AS reference_filename, COALESCE(r.path, '') AS reference_path
                FROM duplicate_groups g
                LEFT JOIN files r ON r.id = g.reference_file_id
                """
            var values: [(any DatabaseValueConvertible)?] = []
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                sql += """
                     WHERE EXISTS (SELECT 1 FROM files m WHERE m.content_hash = g.content_hash
                                   AND (m.filename LIKE ? ESCAPE '\\' OR m.parent_path LIKE ? ESCAPE '\\'))
                    """
                let pattern = "%" + SQL.escapeLike(trimmed) + "%"
                values += [pattern, pattern]
            }
            sql += " ORDER BY g.reclaimable_bytes DESC, g.id LIMIT ? OFFSET ?"
            values += [limit, offset]
            return try Row.fetchAll(db, sql: sql, arguments: SQL.arguments(values)).map { row in
                DuplicateGroupSummary(
                    id: row["id"],
                    contentHash: row["content_hash"],
                    sizeBytes: row["size_bytes"],
                    fileCount: row["file_count"],
                    reclaimableBytes: row["reclaimable_bytes"],
                    referenceFileId: row["reference_file_id"],
                    referenceFilename: row["reference_filename"],
                    referencePath: row["reference_path"],
                    preferredFileId: row["preferred_file_id"]
                )
            }
        }
    }

    public func members(contentHash: String) async throws -> [FileListItem] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                \(FileQueryRepository.listSelect)
                WHERE f.content_hash = ? AND f.availability = 'available' AND f.item_kind = 'regular'
                ORDER BY f.created_at, f.path
                """, arguments: [contentHash]).map(FileListItem.init(row:))
        }
    }
}
