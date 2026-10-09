import GRDB
import XCTest
@testable import FileIntelligenceKit

final class FileOperationTests: XCTestCase {
    func testArchiveMovesFileAndRecordFollows() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/old.zip", "payload")
        let archive = try sandbox.makeFolder("Root/Archive")
        try await sandbox.scan(root)
        let id = try XCTUnwrap(sandbox.record(at: "Root/old.zip")?.id)

        let outcome = try await sandbox.environment.fileOperations.archive(fileIds: [id], to: URL(fileURLWithPath: archive))
        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("Root/old.zip")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path("Root/Archive/old.zip")))

        await sandbox.environment.indexing.applyChanges(outcome.changedFolders.map { DirectoryChange(path: $0, recursive: false) })
        let moved = try XCTUnwrap(sandbox.record(at: "Root/Archive/old.zip"))
        XCTAssertEqual(moved.id, id)
        XCTAssertEqual(moved.reviewStatus, .archived)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM file_actions WHERE action_type = 'archive' AND result = 'succeeded'"), 1)
    }

    func testArchiveNeverReplacesExistingItem() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "original")
        try sandbox.write("Archive/a.txt", "already there")
        try await sandbox.scan(root)
        let id = try XCTUnwrap(sandbox.record(at: "Root/a.txt")?.id)

        let outcome = try await sandbox.environment.fileOperations.archive(fileIds: [id], to: URL(fileURLWithPath: sandbox.path("Archive")))
        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(try String(contentsOfFile: sandbox.path("Root/a.txt")), "original")
        XCTAssertEqual(try String(contentsOfFile: sandbox.path("Archive/a.txt")), "already there")
        XCTAssertEqual(try sandbox.record(at: "Root/a.txt")?.reviewStatus, .unreviewed)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM file_actions WHERE result = 'failed'"), 1)
    }
}
