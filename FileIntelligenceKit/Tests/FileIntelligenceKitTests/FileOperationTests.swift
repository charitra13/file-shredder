import GRDB
import XCTest
@testable import FileIntelligenceKit

final class FileOperationTests: XCTestCase {
    // Only the refusal path is tested: a successful trash would move fixtures into the user's real Trash.
    func testTrashRefusesItemsThatAreNotAvailable() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/gone.txt", "payload")
        try await sandbox.scan(root)
        let id = try XCTUnwrap(sandbox.record(at: "Root/gone.txt")?.id)
        try FileManager.default.removeItem(atPath: sandbox.path("Root/gone.txt"))
        try await sandbox.scan(root)
        XCTAssertEqual(try sandbox.record(at: "Root/gone.txt")?.availability, .missing)

        let outcome = try await sandbox.environment.fileOperations.moveToTrash(fileIds: [id])
        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.changedFolders, [])
        XCTAssertEqual(try sandbox.record(at: "Root/gone.txt")?.reviewStatus, .unreviewed)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM file_actions WHERE action_type = 'trash' AND result = 'failed'"), 1)
    }
}
