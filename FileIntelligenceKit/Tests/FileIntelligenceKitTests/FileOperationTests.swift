import GRDB
import XCTest
@testable import FileIntelligenceKit

final class FileOperationTests: XCTestCase {
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

    func testTrashRefusesChangedSize() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        let path = try sandbox.write("Root/item.txt", "original")
        try await sandbox.scan(root)
        let original = try XCTUnwrap(sandbox.record(at: "Root/item.txt"))
        try sandbox.write("Root/item.txt", "longer new content")
        try FileManager.default.setAttributes([.modificationDate: XCTUnwrap(original.modifiedAt)], ofItemAtPath: path)

        let outcome = try await moveToTemporaryTrash([XCTUnwrap(original.id)], in: sandbox)

        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try sandbox.record(at: "Root/item.txt")?.reviewStatus, .unreviewed)
    }

    func testTrashRefusesModifiedDuplicate() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "same content")
        let path = try sandbox.write("Root/b.txt", "same content")
        try await sandbox.scan(root)
        try await sandbox.process()
        let original = try XCTUnwrap(sandbox.record(at: "Root/b.txt"))
        XCTAssertNotNil(original.contentHash)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM duplicate_groups"), 1)
        try sandbox.write("Root/b.txt", "unique work!")
        try FileManager.default.setAttributes(
            [.modificationDate: XCTUnwrap(original.modifiedAt).addingTimeInterval(60)], ofItemAtPath: path
        )

        let outcome = try await moveToTemporaryTrash([XCTUnwrap(original.id)], in: sandbox)

        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertTrue(outcome.failures.first?.contains("Rescan") == true)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "unique work!")
    }

    func testTrashRefusesReplacementWithMatchingSizeAndModificationDate() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        let path = try sandbox.write("Root/item.txt", "original")
        try await sandbox.scan(root)
        let original = try XCTUnwrap(sandbox.record(at: "Root/item.txt"))
        try FileManager.default.moveItem(atPath: path, toPath: sandbox.path("saved-original.txt"))
        try sandbox.write("Root/item.txt", "replaced")
        try FileManager.default.setAttributes([.modificationDate: XCTUnwrap(original.modifiedAt)], ofItemAtPath: path)

        let outcome = try await moveToTemporaryTrash([XCTUnwrap(original.id)], in: sandbox)

        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "replaced")
    }

    func testTrashRefusesChangedVolumeIdentity() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        let path = try sandbox.write("Root/item.txt", "payload")
        try await sandbox.scan(root)
        let id = try XCTUnwrap(sandbox.record(at: "Root/item.txt")?.id)
        try await sandbox.database.writer.write { db in
            try db.execute(sql: "UPDATE files SET volume_uuid = 'another-volume' WHERE id = ?", arguments: [id])
        }

        let outcome = try await moveToTemporaryTrash([id], in: sandbox)

        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSuccessfulMovesReconcileOnlySourceFolders() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        let path = try sandbox.write("Root/item.txt", "payload")
        try await sandbox.scan(root)
        let id = try XCTUnwrap(sandbox.record(at: "Root/item.txt")?.id)

        let outcome = try await moveToTemporaryTrash([id], in: sandbox)

        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.changedFolders, [root.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path("Root/.Trash/item.txt")))
        let destination = try await sandbox.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT destination_path FROM file_actions WHERE file_id = ?", arguments: [id])
        }
        XCTAssertEqual(destination, sandbox.path("Root/.Trash/item.txt"))

        await sandbox.environment.indexing.applyChanges(outcome.changedFolders.map { DirectoryChange(path: $0, recursive: false) })

        XCTAssertEqual(try sandbox.record(at: "Root/item.txt")?.availability, .missing)
        XCTAssertEqual(try sandbox.record(at: "Root/item.txt")?.reviewStatus, .trashed)
        XCTAssertNil(try sandbox.record(at: "Root/.Trash/item.txt"))
    }

    func testTrashAcceptsUnchangedFoldersPackagesAndSymbolicLinks() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/Folder/item.txt", "payload")
        try sandbox.write("Root/Example.app/Contents/item.txt", "package payload")
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("Root/link"), withDestinationPath: "Folder")
        try await sandbox.scan(root)
        let ids = try ["Root/Folder", "Root/Example.app", "Root/link"].map {
            try XCTUnwrap(sandbox.record(at: $0)?.id)
        }

        let outcome = try await moveToTemporaryTrash(ids, in: sandbox)

        XCTAssertEqual(outcome.succeeded, 3)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.changedFolders, [root.path])
    }

    func testPostMoveFailuresPreserveOutcomesForReconciliation() async throws {
        for failure in ["save", "score"] {
            let sandbox = try TestSandbox()
            let root = try await sandbox.addRoot("Root")
            let path = try sandbox.write("Root/item.txt", "payload")
            try sandbox.write("Root/changed.txt", "original")
            try await sandbox.scan(root)
            let id = try XCTUnwrap(sandbox.record(at: "Root/item.txt")?.id)
            let changedId = try XCTUnwrap(sandbox.record(at: "Root/changed.txt")?.id)
            try sandbox.write("Root/changed.txt", "changed since indexing")
            let trigger = failure == "save" ? "BEFORE INSERT ON file_actions" : "BEFORE UPDATE OF cleanup_priority ON files"
            try await sandbox.database.writer.write { db in
                try db.execute(sql: "CREATE TRIGGER fail_completion \(trigger) BEGIN SELECT RAISE(ABORT, 'forced completion failure'); END")
            }

            let outcome: FileOperationService.Outcome
            do {
                _ = try await moveToTemporaryTrash([id, changedId], in: sandbox)
                XCTFail("Expected a \(failure) error after the move")
                continue
            } catch let error as FileOperationService.CompletionError {
                outcome = error.outcome
                XCTAssertTrue(error.underlyingError.localizedDescription.contains("forced completion failure"))
                XCTAssertFalse(error.localizedDescription.contains("forced completion failure"))
            }

            XCTAssertEqual(outcome.succeeded, 1)
            XCTAssertEqual(outcome.failures.count, 1)
            XCTAssertTrue(outcome.failures.first?.contains("changed.txt") == true)
            XCTAssertEqual(outcome.changedFolders, [root.path])
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path("Root/.Trash/item.txt")))
            XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM file_actions WHERE result = 'succeeded'"), failure == "save" ? 0 : 1)

            try await sandbox.database.writer.write { db in
                try db.execute(sql: "DROP TRIGGER fail_completion")
            }
            await sandbox.environment.indexing.applyChanges(outcome.changedFolders.map { DirectoryChange(path: $0, recursive: false) })

            XCTAssertEqual(try sandbox.record(at: "Root/item.txt")?.availability, .missing)
            XCTAssertNil(try sandbox.record(at: "Root/.Trash/item.txt"))
        }
    }

    // Exercise completed moves without putting fixtures in the user's real Trash.
    private func moveToTemporaryTrash(_ ids: [Int64], in sandbox: TestSandbox) async throws -> FileOperationService.Outcome {
        let trash = try sandbox.makeFolder("Root/.Trash")
        return try await sandbox.environment.fileOperations.move(ids, action: .trash, status: .trashed, now: Date()) { url in
            let destination = PathUtilities.join(trash, url.lastPathComponent)
            try FileManager.default.moveItem(atPath: url.path, toPath: destination)
            return destination
        }
    }
}
