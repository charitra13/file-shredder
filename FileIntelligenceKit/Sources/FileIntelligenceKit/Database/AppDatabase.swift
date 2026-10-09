import Foundation
import GRDB

/// Owns the SQLite connection pool and applies migrations on open.
public final class AppDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter

    public var reader: any DatabaseReader { writer }

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.migrator.migrate(writer)
    }

    /// Opens (or creates) the on-disk index using WAL mode, so the UI can read while indexing writes.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "FileIntelligence.index"
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(pool)
    }

    /// The default index location inside Application Support (the app container when sandboxed).
    public static func defaultLocation() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("FileIntelligence", isDirectory: true)
            .appendingPathComponent("index.sqlite", isDirectory: false)
    }

    /// Marks scans that were running when the app last quit as interrupted.
    ///
    /// Interrupted scans never mark files missing: missing-file detection only runs after a complete pass.
    @discardableResult
    public func recoverInterruptedScans(now: Date = Date()) throws -> Int {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE scan_runs SET state = ?, finished_at = ? WHERE state = ?",
                arguments: [ScanRunState.interrupted, now, ScanRunState.running]
            )
            let count = db.changesCount
            try db.execute(
                sql: "UPDATE scan_roots SET scan_state = ? WHERE scan_state = ?",
                arguments: [RootScanState.interrupted, RootScanState.scanning]
            )
            return count
        }
    }
}
