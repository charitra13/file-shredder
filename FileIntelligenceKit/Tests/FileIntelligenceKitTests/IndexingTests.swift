import GRDB
import XCTest
@testable import FileIntelligenceKit

final class IndexingTests: XCTestCase {
    func testInitialScanPersistsAllItems() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "a")
        try sandbox.write("Root/Sub/b.bin", data: .repeating(0, count: 10))
        try sandbox.write("Root/Sub/no_extension", "c")

        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.added, 4)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files"), 4)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files WHERE item_kind = 'directory'"), 1)
        let rootState = try await sandbox.environment.registry.root(id: XCTUnwrap(root.id))
        XCTAssertEqual(rootState?.scanState, .idle)
        XCTAssertNotNil(rootState?.lastSuccessfulScanAt)
    }

    func testRescanDoesNotDuplicateRecords() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "a")
        try sandbox.write("Root/Sub/b.txt", "b")
        try await sandbox.scan(root)
        let firstIds = try await sandbox.database.reader.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM files ORDER BY id") }

        let second = try await sandbox.scan(root)

        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.unchanged, 3)
        let secondIds = try await sandbox.database.reader.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM files ORDER BY id") }
        XCTAssertEqual(firstIds, secondIds)
    }

    func testChangedFileIsUpdatedAndDerivedDataInvalidated() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "original")
        try await sandbox.scan(root)
        try await sandbox.process()
        let before = try XCTUnwrap(sandbox.record(at: "Root/a.txt"))
        XCTAssertNotNil(before.classifiedAt)
        try await sandbox.setReviewStatus(.keep, at: "Root/a.txt")

        try sandbox.write("Root/a.txt", "changed contents that are longer")
        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.updated, 1)
        let after = try XCTUnwrap(sandbox.record(at: "Root/a.txt"))
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.sizeBytes, 32)
        XCTAssertNil(after.classifiedAt, "Automatic classification is redone after a content change")
        XCTAssertNil(after.contentHash)
        XCTAssertEqual(after.reviewStatus, .keep, "Review decisions survive content changes")
    }

    func testRenameKeepsIdentityAndDecisions() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/draft.txt", "content")
        try await sandbox.scan(root)
        let original = try XCTUnwrap(sandbox.record(at: "Root/draft.txt"))
        try await sandbox.setReviewStatus(.keep, at: "Root/draft.txt")

        try FileManager.default.moveItem(atPath: sandbox.path("Root/draft.txt"), toPath: sandbox.path("Root/final.txt"))
        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.missing, 0)
        let renamed = try XCTUnwrap(sandbox.record(at: "Root/final.txt"))
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.reviewStatus, .keep)
        XCTAssertNil(try sandbox.record(at: "Root/draft.txt"))
    }

    func testMovingFolderMovesDescendantsWithIdentity() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/Old/Deep/file.txt", "x")
        try await sandbox.scan(root)
        let original = try XCTUnwrap(sandbox.record(at: "Root/Old/Deep/file.txt"))

        try sandbox.makeFolder("Root/Archive")
        try FileManager.default.moveItem(atPath: sandbox.path("Root/Old"), toPath: sandbox.path("Root/Archive/New"))
        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.missing, 0)
        XCTAssertEqual(try sandbox.record(at: "Root/Archive/New/Deep/file.txt")?.id, original.id)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files"), 4)
    }

    func testHardLinkIsSeparateRecordNotAMove() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "linked")
        try await sandbox.scan(root)

        try FileManager.default.linkItem(atPath: sandbox.path("Root/a.txt"), toPath: sandbox.path("Root/b.txt"))
        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertNotNil(try sandbox.record(at: "Root/a.txt"))
        XCTAssertNotNil(try sandbox.record(at: "Root/b.txt"))
    }

    func testDeletedFileBecomesMissingAndReturns() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/gone.txt", "x")
        try sandbox.write("Root/Folder/inner.txt", "x")
        try await sandbox.scan(root)
        try await sandbox.setReviewStatus(.keep, at: "Root/gone.txt")

        try FileManager.default.removeItem(atPath: sandbox.path("Root/gone.txt"))
        try FileManager.default.removeItem(atPath: sandbox.path("Root/Folder"))
        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.missing, 3)
        let missing = try XCTUnwrap(sandbox.record(at: "Root/gone.txt"))
        XCTAssertEqual(missing.availability, .missing)
        XCTAssertNotNil(missing.missingSince)

        try sandbox.write("Root/gone.txt", "x")
        try await sandbox.scan(root)
        let restored = try XCTUnwrap(sandbox.record(at: "Root/gone.txt"))
        XCTAssertEqual(restored.id, missing.id)
        XCTAssertEqual(restored.availability, .available)
        XCTAssertEqual(restored.reviewStatus, .keep)
    }

    func testOverlappingRootsDoNotDuplicateRecords() async throws {
        let sandbox = try TestSandbox()
        let outer = try await sandbox.addRoot("Outer")
        try sandbox.write("Outer/top.txt", "x")
        try sandbox.write("Outer/Project/code.swift", "let x = 1")
        try await sandbox.scan(outer)
        let codeBefore = try XCTUnwrap(sandbox.record(at: "Outer/Project/code.swift"))
        try await sandbox.setReviewStatus(.keep, at: "Outer/Project/code.swift")

        let inner = try await sandbox.addRoot("Outer/Project")
        // Adding the nested location transfers ownership immediately, keeping the record.
        XCTAssertEqual(try sandbox.record(at: "Outer/Project/code.swift")?.rootId, inner.id)

        try await sandbox.scan(inner)
        try await sandbox.scan(outer)

        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files WHERE filename = 'code.swift'"), 1)
        let code = try XCTUnwrap(sandbox.record(at: "Outer/Project/code.swift"))
        XCTAssertEqual(code.id, codeBefore.id)
        XCTAssertEqual(code.rootId, inner.id)
        XCTAssertEqual(code.availability, .available, "The outer scan must not mark the nested location's files missing")
        XCTAssertEqual(code.reviewStatus, .keep)
        XCTAssertEqual(try sandbox.record(at: "Outer/Project")?.rootId, outer.id)
    }

    func testRemovingNestedRootHandsFilesToOuterRoot() async throws {
        let sandbox = try TestSandbox()
        let outer = try await sandbox.addRoot("Outer")
        let inner = try await sandbox.addRoot("Outer/Inner")
        try sandbox.write("Outer/Inner/file.txt", "x")
        try await sandbox.scan(inner)
        try await sandbox.setReviewStatus(.keep, at: "Outer/Inner/file.txt")

        try await sandbox.environment.registry.removeRoot(id: XCTUnwrap(inner.id))

        let file = try XCTUnwrap(sandbox.record(at: "Outer/Inner/file.txt"))
        XCTAssertEqual(file.rootId, outer.id)
        XCTAssertEqual(file.reviewStatus, .keep)
        try await sandbox.scan(outer)
        XCTAssertEqual(try sandbox.record(at: "Outer/Inner/file.txt")?.id, file.id)
    }

    func testUnavailableRootKeepsFilesAsUnavailable() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Drive")
        try sandbox.write("Drive/photo.jpg", "x")
        try await sandbox.scan(root)

        // Simulate a disconnected drive by making the location disappear.
        try FileManager.default.moveItem(atPath: sandbox.path("Drive"), toPath: sandbox.path("Unplugged"))
        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.state, .unavailable)
        let photo = try XCTUnwrap(sandbox.record(at: "Drive/photo.jpg"))
        XCTAssertEqual(photo.availability, .unavailable, "A missing location must not mark its files deleted")
        let rootState = try await sandbox.environment.registry.root(id: XCTUnwrap(root.id))
        XCTAssertEqual(rootState?.scanState, .unavailable)

        try FileManager.default.moveItem(atPath: sandbox.path("Unplugged"), toPath: sandbox.path("Drive"))
        try await sandbox.scan(root)
        XCTAssertEqual(try sandbox.record(at: "Drive/photo.jpg")?.availability, .available)
    }

    func testCancelledScanMarksNothingMissing() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        for index in 0..<30 {
            try sandbox.write("Root/D\(index)/f.txt", "x")
        }
        try await sandbox.scan(root)
        let total = try sandbox.count("SELECT COUNT(*) FROM files")

        // Run a scan that is cancelled after its first batch.
        let writer = IndexWriter(database: sandbox.database)
        let runId = try writer.beginRun(rootId: XCTUnwrap(root.id), scope: .full(rootPath: root.path), now: Date())
        let request = ScanRequest(scope: .full(rootPath: root.path), exclusions: .default, batchSize: 2)
        let rootId = try XCTUnwrap(root.id)
        let task = Task {
            try await FileScanner().scan(request) { batch in
                _ = try writer.apply(batch.observations, rootId: rootId, runId: runId, now: Date())
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        _ = try? await task.value
        try writer.endRun(runId: runId, rootId: rootId, state: .cancelled, message: nil, totals: ScanOutcome(rootId: rootId, runId: runId, state: .cancelled), now: Date())

        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files WHERE availability != 'available'"), 0)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files"), total)
        let state = try await sandbox.environment.registry.root(id: rootId)?.scanState
        XCTAssertEqual(state, .interrupted)

        let resumed = try await sandbox.scan(root)
        XCTAssertEqual(resumed.state, .completed)
        XCTAssertEqual(resumed.missing, 0)
    }

    func testNewExclusionRemovesOutOfScopeItems() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/node_modules/pkg/index.js", "x")
        try sandbox.write("Root/app.js", "x")
        try await sandbox.scan(root)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files"), 4)

        var exclusions = root.exclusions
        exclusions.excludedDirectoryNames.append("node_modules")
        try await sandbox.environment.registry.updateExclusions(exclusions, rootId: XCTUnwrap(root.id))
        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.removedFromIndex, 3)
        XCTAssertEqual(outcome.missing, 0)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path("Root/node_modules/pkg/index.js")))
    }

    func testUnreadableFolderMarksItsItemsInaccessible() async throws {
        try XCTSkipIf(geteuid() == 0, "Permission checks do not apply to root")
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/Locked/inside.txt", "x")
        try await sandbox.scan(root)

        chmod(sandbox.path("Root/Locked"), 0o000)
        defer { chmod(sandbox.path("Root/Locked"), 0o755) }
        let outcome = try await sandbox.scan(root)

        XCTAssertEqual(outcome.missing, 0)
        XCTAssertEqual(outcome.inaccessible, 1)
        XCTAssertEqual(try sandbox.record(at: "Root/Locked/inside.txt")?.availability, .inaccessible)
    }

    func testShallowChangeScanPicksUpNewFilesAndFolders() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/existing.txt", "x")
        try await sandbox.scan(root)

        try sandbox.write("Root/new.txt", "x")
        try sandbox.write("Root/NewFolder/Deep/nested.txt", "x")
        try FileManager.default.removeItem(atPath: sandbox.path("Root/existing.txt"))
        await sandbox.environment.indexing.applyChanges([DirectoryChange(path: root.path, recursive: false)])

        XCTAssertNotNil(try sandbox.record(at: "Root/new.txt"))
        XCTAssertNotNil(try sandbox.record(at: "Root/NewFolder/Deep/nested.txt"), "New folders are scanned recursively")
        XCTAssertEqual(try sandbox.record(at: "Root/existing.txt")?.availability, .missing)
    }

    func testPausedNestedRootIsCoveredByOuterRoot() async throws {
        let sandbox = try TestSandbox()
        let outer = try await sandbox.addRoot("Outer")
        let inner = try await sandbox.addRoot("Outer/Inner")
        try sandbox.write("Outer/Inner/file.txt", "x")
        try await sandbox.scan(inner)

        try await sandbox.environment.registry.setEnabled(false, rootId: XCTUnwrap(inner.id))
        try await sandbox.scan(outer)

        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files WHERE filename = 'file.txt'"), 1)
        XCTAssertEqual(try sandbox.record(at: "Outer/Inner/file.txt")?.rootId, outer.id)
    }

    func testProtectedLocationsAreRejected() async throws {
        let sandbox = try TestSandbox()
        let registry = RootRegistry(database: sandbox.database, bookmarks: PathOnlyBookmarkManager(), validation: .standard)
        do {
            _ = try await registry.addRoot(at: URL(fileURLWithPath: "/System"))
            XCTFail("Expected protected location error")
        } catch let error as FileIntelligenceError {
            XCTAssertEqual(error, .protectedLocation("/System"))
        }
        do {
            _ = try await registry.addRoot(at: URL(fileURLWithPath: "/"))
            XCTFail("Expected protected location error")
        } catch let error as FileIntelligenceError {
            XCTAssertEqual(error, .protectedLocation("/"))
        }
    }

    func testDuplicateRootIsRejected() async throws {
        let sandbox = try TestSandbox()
        _ = try await sandbox.addRoot("Root")
        do {
            _ = try await sandbox.addRoot("Root")
            XCTFail("Expected duplicate location error")
        } catch let error as FileIntelligenceError {
            XCTAssertEqual(error, .locationAlreadyIndexed(sandbox.path("Root")))
        }
    }

    func testConcurrentScanRequestsShareOneScan() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        for index in 0..<20 {
            try sandbox.write("Root/f\(index).txt", "x")
        }
        let indexing = sandbox.environment.indexing
        let rootId = try XCTUnwrap(root.id)
        async let first = indexing.scan(rootId: rootId, processAfterwards: false)
        async let second = indexing.scan(rootId: rootId, processAfterwards: false)
        let outcomes = try await [first, second]

        XCTAssertTrue(outcomes.allSatisfy { $0.state == .completed })
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files"), 20)
    }
}
