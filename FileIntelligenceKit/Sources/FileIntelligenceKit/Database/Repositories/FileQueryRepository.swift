import Foundation
import GRDB

/// Paginated, indexed queries over the file library. Nothing here loads the whole index into memory.
public struct FileQueryRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    static let listSelect = """
        SELECT f.id, f.filename, f.path, f.parent_path, f.file_extension, f.item_kind, f.uti, f.size_bytes,
               f.modified_at, f.created_at, f.category_id, COALESCE(c.name, '') AS category_name,
               f.review_status, f.availability, f.cleanup_priority, f.cleanup_reasons,
               r.display_name AS root_name,
               (f.content_hash IS NOT NULL AND EXISTS (
                    SELECT 1 FROM duplicate_groups g WHERE g.content_hash = f.content_hash)) AS is_duplicate
        FROM files f
        JOIN scan_roots r ON r.id = f.root_id
        LEFT JOIN categories c ON c.id = f.category_id
        """

    public func fetchPage(_ query: FileQuery, offset: Int, limit: Int) async throws -> [FileListItem] {
        let filter = Self.whereClause(for: query)
        var values = filter.values
        values += [limit, offset]
        let sql = "\(Self.listSelect) WHERE \(filter.sql) ORDER BY \(Self.orderClause(for: query)) LIMIT ? OFFSET ?"
        let arguments = SQL.arguments(values)
        return try await database.reader.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map(FileListItem.init(row:))
        }
    }

    public func summary(_ query: FileQuery) async throws -> QuerySummary {
        let filter = Self.whereClause(for: query)
        let sql = """
            SELECT COUNT(*) AS item_count, COALESCE(SUM(f.size_bytes), 0) AS total_bytes
            FROM files f LEFT JOIN categories c ON c.id = f.category_id
            WHERE \(filter.sql)
            """
        let arguments = SQL.arguments(filter.values)
        return try await database.reader.read { db in
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else {
                return QuerySummary(count: 0, totalBytes: 0)
            }
            return QuerySummary(count: row["item_count"], totalBytes: row["total_bytes"])
        }
    }

    public func detail(fileId: Int64) async throws -> FileDetail? {
        try await database.reader.read { db in
            guard let file = try FileRecord.fetchOne(db, key: fileId) else { return nil }
            let category = try file.categoryId.flatMap { try FileCategory.fetchOne(db, key: $0) }
            let root = try ScanRoot.fetchOne(db, key: file.rootId)
            let tags = try FileTag.fetchAll(db, sql: "SELECT * FROM file_tags WHERE file_id = ? ORDER BY tag", arguments: [fileId])
            let metadata = try FileMetadataRecord.fetchOne(db, key: fileId)

            var group: DuplicateGroup?
            var copies: [FileListItem] = []
            if let hash = file.contentHash {
                group = try DuplicateGroup.fetchOne(db, sql: "SELECT * FROM duplicate_groups WHERE content_hash = ?", arguments: [hash])
                if group != nil {
                    copies = try Row.fetchAll(db, sql: """
                        \(Self.listSelect)
                        WHERE f.content_hash = ? AND f.id != ? AND f.availability = 'available' AND f.item_kind = 'regular'
                        ORDER BY f.path
                        """, arguments: [hash, fileId]).map(FileListItem.init(row:))
                }
            }

            let relationships = try Row.fetchAll(db, sql: """
                SELECT r.id, r.kind, r.is_verified, r.confidence, r.evidence,
                       CASE WHEN r.source_file_id = ? THEN r.target_file_id ELSE r.source_file_id END AS other_id,
                       o.path AS other_path
                FROM file_relationships r
                JOIN files o ON o.id = CASE WHEN r.source_file_id = ? THEN r.target_file_id ELSE r.source_file_id END
                WHERE r.source_file_id = ? OR r.target_file_id = ?
                """, arguments: [fileId, fileId, fileId, fileId]).compactMap { row -> RelatedFile? in
                let kindRaw: String = row["kind"]
                guard let kind = RelationshipKind(rawValue: kindRaw) else { return nil }
                return RelatedFile(
                    relationshipId: row["id"],
                    kind: kind,
                    isVerified: row["is_verified"],
                    confidence: row["confidence"],
                    evidence: row["evidence"],
                    otherFileId: row["other_id"],
                    otherPath: row["other_path"]
                )
            }

            let actions = try FileActionRecord.fetchAll(db, sql: """
                SELECT * FROM file_actions WHERE file_id = ? ORDER BY performed_at DESC LIMIT 50
                """, arguments: [fileId])

            return FileDetail(
                file: file,
                category: category,
                root: root,
                tags: tags,
                metadata: metadata,
                duplicateGroup: group,
                duplicateCopies: copies,
                relationships: relationships,
                actions: actions
            )
        }
    }

    // MARK: - SQL building

    static func whereClause(for query: FileQuery) -> (sql: String, values: [(any DatabaseValueConvertible)?]) {
        var conditions: [String] = []
        var values: [(any DatabaseValueConvertible)?] = []

        func inList<T: DatabaseValueConvertible>(_ column: String, _ items: [T]) {
            guard !items.isEmpty else {
                conditions.append("0")
                return
            }
            conditions.append("\(column) IN (\(SQL.placeholders(items.count)))")
            values += items.map { $0 as (any DatabaseValueConvertible)? }
        }

        inList("f.item_kind", query.itemKinds.map(\.rawValue).sorted())
        if let availability = query.availability {
            inList("f.availability", availability.map(\.rawValue).sorted())
        }
        if let statuses = query.reviewStatuses {
            inList("f.review_status", statuses.map(\.rawValue).sorted())
        }
        if let extensions = query.fileExtensions {
            inList("f.file_extension", extensions.map { $0.lowercased() }.sorted())
        }

        let terms = query.text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        for term in terms {
            let pattern = "%" + SQL.escapeLike(term) + "%"
            conditions.append("(f.filename LIKE ? ESCAPE '\\' OR f.parent_path LIKE ? ESCAPE '\\')")
            values += [pattern, pattern]
        }

        if let categoryId = query.categoryId {
            if query.includeSubcategories {
                conditions.append("(f.category_id = ? OR f.category_id IN (SELECT id FROM categories WHERE parent_id = ?))")
                values += [categoryId, categoryId]
            } else {
                conditions.append("f.category_id = ?")
                values.append(categoryId)
            }
        }
        if query.unclassifiedOnly {
            conditions.append("(f.category_id IS NULL OR c.slug = 'unknown') AND f.item_kind IN ('regular', 'package')")
        }
        if let rootId = query.rootId {
            conditions.append("f.root_id = ?")
            values.append(rootId)
        }
        if let minimum = query.minimumSize {
            conditions.append("f.size_bytes >= ?")
            values.append(minimum)
        }
        if let maximum = query.maximumSize {
            conditions.append("f.size_bytes <= ?")
            values.append(maximum)
        }
        if let after = query.modifiedAfter {
            conditions.append("f.modified_at >= ?")
            values.append(after)
        }
        if let before = query.modifiedBefore {
            conditions.append("f.modified_at < ?")
            values.append(before)
        }
        if query.duplicatesOnly {
            conditions.append("f.content_hash IN (SELECT content_hash FROM duplicate_groups)")
        }
        if let minimumPriority = query.minimumCleanupPriority {
            conditions.append("f.cleanup_priority >= ?")
            values.append(minimumPriority)
        }

        return (conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), values)
    }

    static func orderClause(for query: FileQuery) -> String {
        let direction = query.ascending ? "ASC" : "DESC"
        let column: String
        switch query.sortField {
        case .name: column = "f.filename COLLATE NOCASE"
        case .size: column = "f.size_bytes"
        case .modified: column = "f.modified_at"
        case .created: column = "f.created_at"
        case .category: column = "category_name COLLATE NOCASE"
        case .priority: column = "COALESCE(f.cleanup_priority, -1)"
        case .location: column = "f.parent_path COLLATE NOCASE"
        }
        return "\(column) \(direction), f.id \(direction)"
    }
}

extension FileListItem {
    init(row: Row) {
        let kindRaw: String = row["item_kind"]
        let reviewRaw: String = row["review_status"]
        let availabilityRaw: String = row["availability"]
        let reasonsJSON: String? = row["cleanup_reasons"]
        let reasons = SQL.decodeJSON([CleanupReason].self, from: reasonsJSON) ?? []
        self.init(
            id: row["id"],
            filename: row["filename"],
            path: row["path"],
            parentPath: row["parent_path"],
            fileExtension: row["file_extension"],
            itemKind: ItemKind(rawValue: kindRaw) ?? .other,
            uti: row["uti"],
            sizeBytes: row["size_bytes"],
            modifiedAt: row["modified_at"],
            createdAt: row["created_at"],
            categoryId: row["category_id"],
            categoryName: row["category_name"],
            reviewStatus: ReviewStatus(rawValue: reviewRaw) ?? .unreviewed,
            availability: Availability(rawValue: availabilityRaw) ?? .available,
            cleanupPriority: row["cleanup_priority"],
            topReason: reasons.first(where: { $0.weight > 0 })?.message,
            isDuplicate: row["is_duplicate"],
            rootName: row["root_name"]
        )
    }
}
