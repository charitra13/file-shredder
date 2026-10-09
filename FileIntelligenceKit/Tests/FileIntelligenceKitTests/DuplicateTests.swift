import GRDB
import XCTest
@testable import FileIntelligenceKit

final class DuplicateTests: XCTestCase {
    func testIdenticalContentAcrossRootsAndNamesIsGrouped() async throws {
        let sandbox = try TestSandbox()
        let first = try await sandbox.addRoot("Downloads")
        let second = try await sandbox.addRoot("Documents")
        let payload = Data((0..<4_096).map { UInt8($0 % 251) })
        try sandbox.write("Downloads/report (1).pdf", data: payload)
        try sandbox.write("Documents/Final Report.pdf", data: payload)
        try sandbox.write("Documents/other.pdf", data: Data(payload.reversed()))
        try await sandbox.scan(first)
        try await sandbox.scan(second)
        try await sandbox.process()

        let overview = try await sandbox.environment.duplicates.overview()
        XCTAssertEqual(overview.groupCount, 1)
        XCTAssertEqual(overview.fileCount, 2)
        XCTAssertEqual(overview.reclaimableBytes, 4_096)

        let groups = try await sandbox.environment.duplicates.groups(offset: 0, limit: 10)
        let members = try await sandbox.environment.duplicates.members(contentHash: XCTUnwrap(groups.first?.contentHash))
        XCTAssertEqual(Set(members.map(\.filename)), ["report (1).pdf", "Final Report.pdf"])
        // The same-size file with different bytes was hashed and ruled out.
        let other = try XCTUnwrap(sandbox.record(at: "Documents/other.pdf"))
        XCTAssertNotNil(other.contentHash)
        XCTAssertNotEqual(other.contentHash, groups.first?.contentHash)
    }

    func testSameSizeDifferentContentIsNotDuplicate() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.bin", data: .repeating(1, count: 1_000))
        try sandbox.write("Root/b.bin", data: .repeating(2, count: 1_000))
        try await sandbox.scan(root)
        try await sandbox.process()

        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM duplicate_groups"), 0)
        // Same-size files are hashed to rule out equality, unique sizes are not.
        XCTAssertNotNil(try sandbox.record(at: "Root/a.bin")?.contentHash)
    }

    func testUniqueSizesAndEmptyFilesAreNeverHashed() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/empty1.txt", "")
        try sandbox.write("Root/empty2.txt", "")
        try sandbox.write("Root/unique.txt", "only one of this size")
        try await sandbox.scan(root)
        try await sandbox.process()

        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files WHERE content_hash IS NOT NULL"), 0)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM duplicate_groups"), 0)
    }

    func testQuickHashStageStillFindsDuplicatesOfLargeFiles() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        var settings = AppSettings()
        settings.hashing.quickHashThreshold = 1_024
        try sandbox.environment.preferences.saveSettings(settings)

        var payload = Data((0..<300_000).map { UInt8($0 % 253) })
        try sandbox.write("Root/one.mov", data: payload)
        try sandbox.write("Root/two.mov", data: payload)
        // Same size, same head and tail, different middle: quick hashes match, full hashes differ.
        payload[150_000] ^= 0xFF
        try sandbox.write("Root/three.mov", data: payload)
        try await sandbox.scan(root)
        try await sandbox.process()

        let groups = try await sandbox.environment.duplicates.groups(offset: 0, limit: 10)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.fileCount, 2)
        let three = try XCTUnwrap(sandbox.record(at: "Root/three.mov"))
        let one = try XCTUnwrap(sandbox.record(at: "Root/one.mov"))
        XCTAssertEqual(three.quickHash, one.quickHash)
        XCTAssertNotEqual(three.contentHash, one.contentHash)
    }

    func testHardLinksDoNotCountAsReclaimableStorage() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.dat", data: .repeating(7, count: 2_000))
        try FileManager.default.linkItem(atPath: sandbox.path("Root/a.dat"), toPath: sandbox.path("Root/b.dat"))
        try await sandbox.scan(root)
        try await sandbox.process()

        let overview = try await sandbox.environment.duplicates.overview()
        XCTAssertEqual(overview.groupCount, 1)
        XCTAssertEqual(overview.reclaimableBytes, 0, "Hard links share storage, so removing one frees nothing")
    }

    func testChangedFileLeavesGroupAfterRescan() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "same content")
        try sandbox.write("Root/b.txt", "same content")
        try await sandbox.scan(root)
        try await sandbox.process()
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM duplicate_groups"), 1)

        try sandbox.write("Root/b.txt", "different now")
        try await sandbox.scan(root)
        try await sandbox.process()

        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM duplicate_groups"), 0)
    }

    func testVerifyGroupDetectsChangeBeforeRescan() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "same content")
        try sandbox.write("Root/b.txt", "same content")
        try await sandbox.scan(root)
        try await sandbox.process()
        let hash = try XCTUnwrap(sandbox.record(at: "Root/a.txt")?.contentHash)

        try sandbox.write("Root/b.txt", "edited text!")
        let stillDuplicate = try await sandbox.environment.duplicateDetector.verifyGroup(contentHash: hash)

        XCTAssertFalse(stillDuplicate)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM duplicate_groups"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path("Root/a.txt")), "Duplicate detection never removes files")
    }

    func testPreferredCopyIsKeptAndOthersBecomeCandidates() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/keep-me.txt", "dup")
        try sandbox.write("Root/Copies/copy.txt", "dup")
        try await sandbox.scan(root)
        try await sandbox.process()
        let preferred = try XCTUnwrap(sandbox.record(at: "Root/Copies/copy.txt")?.id)

        try await sandbox.environment.review.setPreferredCopy(fileId: preferred)
        try await sandbox.process()

        let group = try await sandbox.environment.duplicates.groups(offset: 0, limit: 1).first
        XCTAssertEqual(group?.preferredFileId, preferred)
        XCTAssertEqual(group?.referenceFileId, preferred)
        let other = try XCTUnwrap(sandbox.record(at: "Root/keep-me.txt"))
        XCTAssertTrue(other.cleanupReasons?.contains { $0.code == "exactDuplicate" } ?? false)
        let reference = try XCTUnwrap(sandbox.record(at: "Root/Copies/copy.txt"))
        XCTAssertFalse(reference.cleanupReasons?.contains { $0.code == "exactDuplicate" } ?? false)
    }
}
