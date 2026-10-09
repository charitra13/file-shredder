import Foundation
import GRDB
import XCTest
@testable import FileIntelligenceKit

/// An isolated sandbox for one test: a temporary folder for fixtures and a fresh on-disk database.
/// Nothing outside this folder is ever read or modified.
final class TestSandbox {
    let directory: String
    let environment: IndexEnvironment

    var database: AppDatabase { environment.database }

    init(hasher: ContentHasher = ContentHasher(), scanner: FileScanner = FileScanner()) throws {
        let base = PathUtilities.canonicalPath(NSTemporaryDirectory())
        directory = PathUtilities.join(base, "FileIntelligenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: URL(fileURLWithPath: PathUtilities.join(directory, "index.sqlite")))
        environment = IndexEnvironment(
            database: database,
            bookmarks: PathOnlyBookmarkManager(),
            validation: .permissive,
            scanner: scanner,
            hasher: hasher
        )
    }

    deinit {
        // Restore permissions changed by tests so cleanup succeeds.
        if let enumerator = FileManager.default.enumerator(atPath: directory) {
            while let relative = enumerator.nextObject() as? String {
                chmod(PathUtilities.join(directory, relative), 0o755)
            }
        }
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Creates a fixture folder (outside the database file) and returns its canonical path.
    @discardableResult
    func makeFolder(_ relative: String) throws -> String {
        let path = PathUtilities.join(directory, relative)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> String {
        try write(relative, data: Data(contents.utf8))
    }

    @discardableResult
    func write(_ relative: String, data: Data) throws -> String {
        let path = PathUtilities.join(directory, relative)
        try FileManager.default.createDirectory(
            atPath: PathUtilities.parent(of: path),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return path
    }

    func path(_ relative: String) -> String {
        PathUtilities.join(directory, relative)
    }

    func addRoot(_ relative: String, exclusions: ExclusionConfig = .default) async throws -> ScanRoot {
        let path = try makeFolder(relative)
        return try await environment.registry.addRoot(at: URL(fileURLWithPath: path), exclusions: exclusions)
    }

    @discardableResult
    func scan(_ root: ScanRoot) async throws -> ScanOutcome {
        try await environment.indexing.scan(rootId: XCTUnwrap(root.id), processAfterwards: false)
    }

    func process() async throws {
        try await environment.pipeline.run()
    }

    func record(at relative: String) throws -> FileRecord? {
        let fullPath = path(relative)
        return try database.reader.read { db in
            try FileRecord.filter(Column("path") == fullPath).fetchOne(db)
        }
    }

    func count(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> Int {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    func setReviewStatus(_ status: ReviewStatus, at relative: String) async throws {
        let id = try XCTUnwrap(record(at: relative)?.id)
        try await environment.review.setReviewStatus(status, fileIds: [id])
    }
}

extension Data {
    static func repeating(_ byte: UInt8, count: Int) -> Data {
        Data(repeating: byte, count: count)
    }
}
