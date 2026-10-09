import Foundation
import GRDB

/// Aggregate figures computed from the database. Every number shown in the UI comes from here.
public struct StatsRepository: Sendable {
    let database: AppDatabase
    let preferences: PreferencesRepository

    public init(database: AppDatabase, preferences: PreferencesRepository) {
        self.database = database
        self.preferences = preferences
    }

    public func overview() async throws -> OverviewStats {
        let minimumPriority = preferences.loadSettings().scoring.minimumCandidatePriority
        return try await database.reader.read { db in
            let files = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(CASE WHEN item_kind != 'directory' AND availability = 'available' THEN 1 ELSE 0 END), 0) AS items,
                    COALESCE(SUM(CASE WHEN item_kind = 'directory' AND availability = 'available' THEN 1 ELSE 0 END), 0) AS folders,
                    COALESCE(SUM(CASE WHEN item_kind != 'directory' AND availability = 'available' THEN size_bytes ELSE 0 END), 0) AS bytes,
                    COALESCE(SUM(CASE WHEN availability = 'missing' THEN 1 ELSE 0 END), 0) AS missing,
                    COALESCE(SUM(CASE WHEN availability IN ('unavailable', 'inaccessible') THEN 1 ELSE 0 END), 0) AS unavailable,
                    COALESCE(SUM(CASE WHEN item_kind IN ('regular', 'package') AND availability = 'available'
                        AND (classified_at IS NULL OR enriched_at IS NULL OR scored_at IS NULL) THEN 1 ELSE 0 END), 0) AS pending
                FROM files
                """)
            let classification = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(CASE WHEN f.category_id IS NOT NULL AND c.slug != 'unknown' THEN 1 ELSE 0 END), 0) AS classified,
                    COALESCE(SUM(CASE WHEN f.category_id IS NULL OR c.slug = 'unknown' THEN 1 ELSE 0 END), 0) AS unclassified
                FROM files f LEFT JOIN categories c ON c.id = f.category_id
                WHERE f.item_kind IN ('regular', 'package') AND f.availability = 'available'
                """)
            let roots = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                       COALESCE(SUM(CASE WHEN is_enabled = 1 THEN 1 ELSE 0 END), 0) AS enabled,
                       COALESCE(SUM(CASE WHEN scan_state = 'unavailable' THEN 1 ELSE 0 END), 0) AS unavailable
                FROM scan_roots
                """)
            let duplicates = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS group_count, COALESCE(SUM(file_count), 0) AS files, COALESCE(SUM(reclaimable_bytes), 0) AS bytes
                FROM duplicate_groups
                """)
            let candidates = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS items, COALESCE(SUM(size_bytes), 0) AS bytes FROM files
                WHERE availability = 'available' AND cleanup_priority >= ? AND review_status IN ('unreviewed', 'reviewLater')
                """, arguments: [minimumPriority])

            return OverviewStats(
                totalItems: files.int("items"),
                totalFolders: files.int("folders"),
                totalBytes: files.int64("bytes"),
                locationCount: roots.int("total"),
                enabledLocationCount: roots.int("enabled"),
                unavailableLocationCount: roots.int("unavailable"),
                classifiedItems: classification.int("classified"),
                unclassifiedItems: classification.int("unclassified"),
                duplicateGroups: duplicates.int("group_count"),
                duplicateFiles: duplicates.int("files"),
                reclaimableBytes: duplicates.int64("bytes"),
                reviewCandidates: candidates.int("items"),
                reviewCandidateBytes: candidates.int64("bytes"),
                missingItems: files.int("missing"),
                unavailableItems: files.int("unavailable"),
                pendingProcessing: files.int("pending")
            )
        }
    }

    /// Per-location totals, including whether a location is nested inside another.
    public func rootSummaries() async throws -> [RootSummary] {
        try await database.reader.read { db in
            let roots = try ScanRoot.fetchAll(db, sql: "SELECT * FROM scan_roots ORDER BY display_name COLLATE NOCASE")
            let rows = try Row.fetchAll(db, sql: """
                SELECT root_id,
                       SUM(CASE WHEN availability = 'available' AND item_kind != 'directory' THEN 1 ELSE 0 END) AS items,
                       SUM(CASE WHEN availability = 'available' AND item_kind != 'directory' THEN size_bytes ELSE 0 END) AS bytes,
                       SUM(CASE WHEN availability = 'missing' THEN 1 ELSE 0 END) AS missing,
                       SUM(CASE WHEN availability IN ('unavailable', 'inaccessible') THEN 1 ELSE 0 END) AS unavailable
                FROM files GROUP BY root_id
                """)
            var totals: [Int64: Row] = [:]
            for row in rows {
                let rootId: Int64 = row["root_id"]
                totals[rootId] = row
            }
            return roots.map { root in
                let row = root.id.flatMap { totals[$0] }
                let container = RootRegistry.deepest(roots.filter {
                    $0.id != root.id && PathUtilities.isPath(root.path, strictlyInside: $0.path)
                })
                return RootSummary(
                    root: root,
                    itemCount: row.int("items"),
                    totalBytes: row.int64("bytes"),
                    missingCount: row.int("missing"),
                    unavailableCount: row.int("unavailable"),
                    nestedInside: container?.displayName
                )
            }
        }
    }
}
