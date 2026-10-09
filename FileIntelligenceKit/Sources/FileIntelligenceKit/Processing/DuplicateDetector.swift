import Foundation
import GRDB

public struct DuplicateSummary: Sendable, Equatable {
    public var groupCount: Int
    public var reclaimableBytes: Int64
    public var filesHashed: Int
}

/// Finds exact duplicates in stages, hashing only when cheaper evidence cannot rule a file out:
///
/// 1. Group available regular files by size; unique sizes cannot have duplicates.
/// 2. For large files, compare a quick hash of the size, head and tail.
/// 3. Confirm equality with a full SHA-256 of the content.
///
/// Before hashing, each file is re-checked on disk; files that changed since the scan are skipped until rescanned.
/// Similar-looking files are never reported here: a group means byte-for-byte identical content.
public struct DuplicateDetector: Sendable {
    let database: AppDatabase
    let hasher: ContentHasher

    public init(database: AppDatabase, hasher: ContentHasher = ContentHasher()) {
        self.database = database
        self.hasher = hasher
    }

    struct Candidate: Sendable {
        let id: Int64
        let path: String
        let size: Int64
        let modifiedAt: Date?
        var quickHash: String?
        var contentHash: String?
    }

    @discardableResult
    public func run(
        settings: HashingSettings = HashingSettings(),
        progress: @Sendable (ProcessingProgress) -> Void = { _ in }
    ) async throws -> DuplicateSummary {
        let sizes: [Int64] = try await database.reader.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT size_bytes FROM files
                WHERE item_kind = 'regular' AND availability = 'available' AND size_bytes >= ?
                GROUP BY size_bytes HAVING COUNT(*) > 1
                ORDER BY size_bytes DESC
                """, arguments: [max(1, settings.minimumDuplicateSize)])
        }

        var hashed = 0
        for (index, size) in sizes.enumerated() {
            try Task.checkCancellation()
            hashed += try await processBucket(size: size, settings: settings)
            progress(ProcessingProgress(stage: .hashing, completed: index + 1, total: sizes.count))
        }

        let summary = try rebuildGroups(now: Date())
        return DuplicateSummary(groupCount: summary.groups, reclaimableBytes: summary.reclaimable, filesHashed: hashed)
    }

    /// Re-hashes every member of a group from disk, then rebuilds groups. Use before acting on duplicate status.
    @discardableResult
    public func verifyGroup(contentHash: String) async throws -> Bool {
        let members = try await database.reader.read { db in
            try Self.candidates(db, sql: "content_hash = ?", arguments: [contentHash])
        }
        let detector = self
        let results = try await concurrentMap(members, maxConcurrency: 2) { member -> (Int64, String?) in
            (member.id, detector.fullHashIfUnchanged(member))
        }
        try await database.writer.write { db in
            let now = Date()
            for (id, hash) in results {
                let hashedAt: Date? = hash == nil ? nil : now
                try db.execute(
                    sql: "UPDATE files SET content_hash = ?, hashed_at = ? WHERE id = ?",
                    arguments: [hash, hashedAt, id]
                )
            }
        }
        _ = try rebuildGroups(now: Date())
        return results.filter { $0.1 == contentHash }.count > 1
    }

    // MARK: - Stages

    private func processBucket(size: Int64, settings: HashingSettings) async throws -> Int {
        var members = try await database.reader.read { db in
            try Self.candidates(db, sql: "size_bytes = ?", arguments: [size])
        }
        guard members.count > 1 else { return 0 }
        let detector = self
        var hashedCount = 0

        if size >= settings.quickHashThreshold {
            let needQuick = members.filter { $0.quickHash == nil }
            if !needQuick.isEmpty {
                let quick = try await concurrentMap(needQuick, maxConcurrency: settings.maxConcurrentHashes) { member -> (Int64, String?) in
                    (member.id, detector.quickHashIfUnchanged(member))
                }
                try store(quick, column: "quick_hash")
                let byId = Dictionary(quick.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
                for index in members.indices where members[index].quickHash == nil {
                    members[index].quickHash = byId[members[index].id] ?? nil
                }
            }
            // Only files whose quick hash matches another file's can be identical.
            let snapshot = members
            let quickCounts = Dictionary(grouping: snapshot.compactMap(\.quickHash), by: { $0 }).mapValues(\.count)
            members = snapshot.filter { member in
                member.quickHash.map { (quickCounts[$0] ?? 0) > 1 } ?? false
            }
            guard members.count > 1 else { return 0 }
        }

        let needFull = members.filter { $0.contentHash == nil }
        guard !needFull.isEmpty else { return 0 }
        let full = try await concurrentMap(needFull, maxConcurrency: settings.maxConcurrentHashes) { member -> (Int64, String?) in
            (member.id, detector.fullHashIfUnchanged(member))
        }
        try store(full, column: "content_hash")
        hashedCount += full.filter { $0.1 != nil }.count
        return hashedCount
    }

    func quickHashIfUnchanged(_ candidate: Candidate) -> String? {
        guard isUnchanged(candidate) else { return nil }
        return try? hasher.quickHash(path: candidate.path, size: candidate.size)
    }

    func fullHashIfUnchanged(_ candidate: Candidate) -> String? {
        guard isUnchanged(candidate) else { return nil }
        guard let hash = try? hasher.sha256(path: candidate.path) else { return nil }
        // Guard against the file changing while it was being read.
        return isUnchanged(candidate) ? hash : nil
    }

    private func isUnchanged(_ candidate: Candidate) -> Bool {
        guard case .success(let info) = FileStat.read(candidate.path), info.kind == .regular else { return false }
        return info.size == candidate.size && DateUtilities.approximatelyEqual(info.modifiedAt, candidate.modifiedAt)
    }

    private func store(_ values: [(Int64, String?)], column: String) throws {
        let now = Date()
        try database.writer.write { db in
            let sql = column == "content_hash"
                ? "UPDATE files SET content_hash = ?, hashed_at = ? WHERE id = ? AND content_hash IS NULL"
                : "UPDATE files SET quick_hash = ? WHERE id = ?"
            let statement = try db.cachedStatement(sql: sql)
            for (id, hash) in values where hash != nil {
                if column == "content_hash" {
                    try statement.execute(arguments: [hash, now, id])
                } else {
                    try statement.execute(arguments: [hash, id])
                }
            }
        }
    }

    private static func candidates(_ db: Database, sql condition: String, arguments: StatementArguments) throws -> [Candidate] {
        try Row.fetchAll(db, sql: """
            SELECT id, path, size_bytes, modified_at, quick_hash, content_hash FROM files
            WHERE item_kind = 'regular' AND availability = 'available' AND \(condition)
            """, arguments: arguments).map { row in
            Candidate(
                id: row["id"],
                path: row["path"],
                size: row["size_bytes"],
                modifiedAt: row["modified_at"],
                quickHash: row["quick_hash"],
                contentHash: row["content_hash"]
            )
        }
    }

    // MARK: - Groups

    /// Recomputes `duplicate_groups` from content hashes, preserving the user's preferred copies.
    @discardableResult
    func rebuildGroups(now: Date) throws -> (groups: Int, reclaimable: Int64) {
        try database.writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT content_hash, size_bytes, COUNT(*) AS file_count,
                       COUNT(DISTINCT COALESCE(volume_uuid, '') || ':' || COALESCE(inode, -id)) AS distinct_items
                FROM files
                WHERE content_hash IS NOT NULL AND availability = 'available' AND item_kind = 'regular'
                GROUP BY content_hash HAVING COUNT(*) > 1
                """)
            var existing: [String: DuplicateGroup] = [:]
            for group in try DuplicateGroup.fetchAll(db) {
                existing[group.contentHash] = group
            }

            var seen = Set<String>()
            var reclaimable: Int64 = 0
            for row in rows {
                let hash: String = row["content_hash"]
                let size: Int64 = row["size_bytes"]
                let count: Int = row["file_count"]
                let distinct: Int = row["distinct_items"]
                seen.insert(hash)

                let members = try Row.fetchAll(db, sql: """
                    SELECT id, path, created_at, review_status FROM files
                    WHERE content_hash = ? AND availability = 'available' AND item_kind = 'regular'
                    """, arguments: [hash])
                let memberIds = Set(members.map { $0["id"] as Int64 })

                var group = existing[hash] ?? DuplicateGroup(
                    id: nil, contentHash: hash, sizeBytes: size, fileCount: count, distinctItemCount: distinct,
                    reclaimableBytes: 0, preferredFileId: nil, referenceFileId: nil, updatedAt: now
                )
                if let preferred = group.preferredFileId, !memberIds.contains(preferred) {
                    group.preferredFileId = nil
                }
                group.sizeBytes = size
                group.fileCount = count
                group.distinctItemCount = distinct
                group.reclaimableBytes = Int64(max(0, distinct - 1)) * size
                group.referenceFileId = group.preferredFileId ?? Self.defaultReference(members)
                group.updatedAt = now
                try group.save(db)
                reclaimable += group.reclaimableBytes
            }

            let stale = existing.keys.filter { !seen.contains($0) }
            for hash in stale {
                try db.execute(sql: "DELETE FROM duplicate_groups WHERE content_hash = ?", arguments: [hash])
            }
            return (rows.count, reclaimable)
        }
    }

    /// A copy marked Keep, else the oldest by creation date, else the shortest path.
    static func defaultReference(_ members: [Row]) -> Int64? {
        let sorted = members.sorted { lhs, rhs in
            let lhsKeep = (lhs["review_status"] as String) == ReviewStatus.keep.rawValue
            let rhsKeep = (rhs["review_status"] as String) == ReviewStatus.keep.rawValue
            if lhsKeep != rhsKeep { return lhsKeep }
            let lhsDate = (lhs["created_at"] as Date?) ?? .distantFuture
            let rhsDate = (rhs["created_at"] as Date?) ?? .distantFuture
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            let lhsPath: String = lhs["path"]
            let rhsPath: String = rhs["path"]
            if lhsPath.count != rhsPath.count { return lhsPath.count < rhsPath.count }
            return lhsPath < rhsPath
        }
        return sorted.first.map { $0["id"] as Int64 }
    }
}
