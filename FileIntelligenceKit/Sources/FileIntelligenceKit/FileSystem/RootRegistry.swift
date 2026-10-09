import Foundation
import GRDB

/// Manages user-approved locations, their security-scoped access, and ownership of overlapping locations.
///
/// Ownership rule: every indexed item belongs to exactly one location, the deepest *enabled* location that
/// contains it. A scan skips folders owned by nested locations, so overlapping selections never produce
/// duplicate records, and each scan only reconciles the items it owns.
public actor RootRegistry {
    private let database: AppDatabase
    private let bookmarks: any BookmarkManaging
    private let validation: RootValidationPolicy
    private var accessedURLs: [Int64: URL] = [:]

    public init(database: AppDatabase, bookmarks: any BookmarkManaging, validation: RootValidationPolicy) {
        self.database = database
        self.bookmarks = bookmarks
        self.validation = validation
    }

    // MARK: - Queries

    public func allRoots() async throws -> [ScanRoot] {
        try await database.reader.read { db in
            try ScanRoot.fetchAll(db, sql: "SELECT * FROM scan_roots ORDER BY display_name COLLATE NOCASE")
        }
    }

    public func root(id: Int64) async throws -> ScanRoot? {
        try await database.reader.read { db in
            try ScanRoot.fetchOne(db, key: id)
        }
    }

    /// Paths of enabled locations strictly inside `rootId`'s folder.
    public func nestedEnabledRootPaths(of rootId: Int64) async throws -> Set<String> {
        let roots = try await allRoots()
        guard let root = roots.first(where: { $0.id == rootId }) else { return [] }
        return Set(roots.filter {
            $0.id != rootId && $0.isEnabled && PathUtilities.isPath($0.path, strictlyInside: root.path)
        }.map(\.path))
    }

    /// The deepest enabled location containing `path` (or equal to it).
    public func owningRoot(for path: String) async throws -> ScanRoot? {
        let roots = try await allRoots()
        return Self.deepest(roots.filter { $0.isEnabled && PathUtilities.isPath(path, inside: $0.path) })
    }

    // MARK: - Mutations

    /// Registers a folder or volume chosen by the user. Throws for protected or duplicate locations.
    public func addRoot(at url: URL, displayName: String? = nil, exclusions: ExclusionConfig = .default) async throws -> ScanRoot {
        let path = PathUtilities.canonicalPath(url.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw FileIntelligenceError.locationNotFound(path)
        }
        guard isDirectory.boolValue else {
            throw FileIntelligenceError.notADirectory(path)
        }
        try validation.validate(path)

        let bookmark = try? bookmarks.createBookmark(for: url)
        let volume = VolumeInfo.describe(URL(fileURLWithPath: path, isDirectory: true))
        let name = displayName ?? FileManager.default.displayName(atPath: path)
        let ancestorIds = try await allRoots()
            .filter { PathUtilities.isPath(path, strictlyInside: $0.path) }
            .compactMap(\.id)
        let now = Date()

        let root = try await database.writer.write { db -> ScanRoot in
            if try ScanRoot.filter(Column("path") == path).fetchCount(db) > 0 {
                throw FileIntelligenceError.locationAlreadyIndexed(path)
            }
            var root = ScanRoot(
                id: nil,
                displayName: name,
                path: path,
                bookmark: bookmark,
                rootType: volume.rootType,
                volumeUUID: volume.volumeUUID,
                isEnabled: true,
                scanState: .idle,
                lastSuccessfulScanAt: nil,
                lastScanStartedAt: nil,
                exclusions: exclusions,
                lastError: nil,
                createdAt: now
            )
            try root.insert(db)
            if let id = root.id {
                try Self.adoptDescendants(db, rootId: id, path: path, fromRoots: ancestorIds)
            }
            return root
        }
        if let id = root.id {
            _ = try await ensureAccess(rootId: id)
        }
        return root
    }

    /// Removes a location from the index. Files on disk are never touched.
    ///
    /// Items that are also inside an enabled outer location are handed to it, keeping their review decisions.
    public func removeRoot(id: Int64) async throws {
        let roots = try await allRoots()
        guard let root = roots.first(where: { $0.id == id }) else {
            throw FileIntelligenceError.rootNotFound(id)
        }
        let heir = Self.deepest(roots.filter {
            $0.id != id && $0.isEnabled && PathUtilities.isPath(root.path, strictlyInside: $0.path)
        })
        try await database.writer.write { db in
            if let heirId = heir?.id {
                try db.execute(sql: "UPDATE files SET root_id = ? WHERE root_id = ?", arguments: [heirId, id])
            }
            _ = try ScanRoot.deleteOne(db, key: id)
        }
        stopAccess(rootId: id)
    }

    /// Pauses or resumes a location. Pausing keeps its index; an enabled outer location takes over its items.
    public func setEnabled(_ enabled: Bool, rootId: Int64) async throws {
        let roots = try await allRoots()
        guard let root = roots.first(where: { $0.id == rootId }) else {
            throw FileIntelligenceError.rootNotFound(rootId)
        }
        let ancestors = roots.filter { $0.id != rootId && PathUtilities.isPath(root.path, strictlyInside: $0.path) }
        let heir = Self.deepest(ancestors.filter(\.isEnabled))
        let ancestorIds = ancestors.compactMap(\.id)

        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE scan_roots SET is_enabled = ?, scan_state = ? WHERE id = ?",
                arguments: [enabled, RootScanState.idle, rootId]
            )
            if enabled {
                try Self.adoptDescendants(db, rootId: rootId, path: root.path, fromRoots: ancestorIds)
            } else if let heirId = heir?.id {
                try db.execute(sql: "UPDATE files SET root_id = ? WHERE root_id = ?", arguments: [heirId, rootId])
            }
        }
        if enabled {
            _ = try await ensureAccess(rootId: rootId)
        }
    }

    public func rename(rootId: Int64, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileIntelligenceError.invalidInput("A location name can’t be empty.") }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE scan_roots SET display_name = ? WHERE id = ?", arguments: [trimmed, rootId])
        }
    }

    /// Changes a location's exclusions. Items that fall out of scope are removed on its next full scan.
    public func updateExclusions(_ exclusions: ExclusionConfig, rootId: Int64) async throws {
        guard let json = SQL.encodeJSON(exclusions) else { return }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE scan_roots SET exclusions = ? WHERE id = ?", arguments: [json, rootId])
        }
    }

    // MARK: - Security-scoped access

    /// Starts security-scoped access for every enabled location. Call once at launch.
    public func startAccessingEnabledRoots() async {
        guard let roots = try? await allRoots() else { return }
        for root in roots where root.isEnabled {
            if let id = root.id {
                _ = try? await ensureAccess(rootId: id)
            }
        }
    }

    /// Resolves the location's bookmark, starts access if needed, and returns its current path.
    ///
    /// When a bookmark resolves to a new path (the folder was moved or renamed), the stored path is updated;
    /// the next scan then reconciles item paths by filesystem identity.
    public func ensureAccess(rootId: Int64) async throws -> String {
        guard var root = try await self.root(id: rootId) else {
            throw FileIntelligenceError.rootNotFound(rootId)
        }
        if accessedURLs[rootId] != nil { return root.path }
        guard let data = root.bookmark, let resolved = try? bookmarks.resolveBookmark(data) else {
            return root.path
        }

        bookmarks.startAccessing(resolved.url)
        accessedURLs[rootId] = resolved.url

        var changed = false
        if resolved.isStale, let fresh = try? bookmarks.createBookmark(for: resolved.url) {
            root.bookmark = fresh
            changed = true
        }
        let resolvedPath = PathUtilities.canonicalPath(resolved.url.path)
        if resolvedPath != root.path && PathUtilities.isReachableDirectory(resolvedPath) {
            root.path = resolvedPath
            changed = true
        }
        if changed {
            let updated = root
            try? await database.writer.write { db in try updated.update(db) }
        }
        return root.path
    }

    public func stopAccess(rootId: Int64) {
        if let url = accessedURLs.removeValue(forKey: rootId) {
            bookmarks.stopAccessing(url)
        }
    }

    // MARK: - Helpers

    static func deepest(_ roots: [ScanRoot]) -> ScanRoot? {
        roots.max { $0.path.count < $1.path.count }
    }

    /// Moves ownership of items under `path` from the given ancestor locations to `rootId`.
    private static func adoptDescendants(_ db: Database, rootId: Int64, path: String, fromRoots ancestorIds: [Int64]) throws {
        guard !ancestorIds.isEmpty else { return }
        let range = SQL.descendantRange(of: path)
        var values: [(any DatabaseValueConvertible)?] = [rootId, range.lower, range.upper]
        values.append(contentsOf: ancestorIds.map { $0 as (any DatabaseValueConvertible)? })
        try db.execute(
            sql: "UPDATE files SET root_id = ? WHERE path >= ? AND path < ? AND root_id IN (\(SQL.placeholders(ancestorIds.count)))",
            arguments: SQL.arguments(values)
        )
    }
}
