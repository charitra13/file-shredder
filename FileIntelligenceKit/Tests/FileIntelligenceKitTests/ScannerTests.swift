import XCTest
@testable import FileIntelligenceKit

final class ScannerTests: XCTestCase {
    private func collect(_ request: ScanRequest) async throws -> ([FileObservation], ScanTraversalSummary, [ScanIssueInfo]) {
        var observations: [FileObservation] = []
        var issues: [ScanIssueInfo] = []
        let summary = try await FileScanner().scan(request) { batch in
            observations += batch.observations
            issues += batch.issues
        }
        return (observations, summary, issues)
    }

    private func request(_ root: String, exclusions: ExclusionConfig = .default, skipped: Set<String> = []) -> ScanRequest {
        ScanRequest(scope: .full(rootPath: root), exclusions: exclusions, skippedSubtrees: skipped, batchSize: 3)
    }

    func testRecordsUnknownAndExtensionlessFiles() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.makeFolder("Root")
        try sandbox.write("Root/notes", "no extension")
        try sandbox.write("Root/data.zzqx", "unknown extension")
        try sandbox.write("Root/Sub/report.pdf", "%PDF-1.7 fake")

        let (observations, summary, _) = try await collect(request(root))
        let names = Set(observations.map(\.filename))

        XCTAssertEqual(names, ["notes", "data.zzqx", "Sub", "report.pdf"])
        XCTAssertEqual(summary.itemsSeen, 4)
        let notes = try XCTUnwrap(observations.first { $0.filename == "notes" })
        XCTAssertNil(notes.fileExtension)
        XCTAssertNil(notes.uti)
        XCTAssertEqual(notes.itemKind, .regular)
        XCTAssertEqual(notes.sizeBytes, 12)
        XCTAssertNotNil(notes.inode)
        XCTAssertNotNil(notes.volumeUUID)
        let pdf = try XCTUnwrap(observations.first { $0.filename == "report.pdf" })
        XCTAssertEqual(pdf.uti, "com.adobe.pdf")
        XCTAssertEqual(pdf.parentPath, sandbox.path("Root/Sub"))
    }

    func testExclusionsAndHiddenFiles() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.makeFolder("Root")
        try sandbox.write("Root/.DS_Store", "x")
        try sandbox.write("Root/.hidden", "x")
        try sandbox.write("Root/.Trash/deleted.txt", "x")
        try sandbox.write("Root/.git/objects/abc", "object")
        try sandbox.write("Root/visible.txt", "x")

        let (withHidden, _, _) = try await collect(request(root))
        XCTAssertEqual(Set(withHidden.map(\.filename)), [".hidden", ".git", "visible.txt"])
        let git = try XCTUnwrap(withHidden.first { $0.filename == ".git" })
        XCTAssertEqual(git.itemKind, .directory)
        XCTAssertEqual(git.sizeBytes, 6, "Opaque folders are recorded with an estimated size but not descended into")

        var noHidden = ExclusionConfig.default
        noHidden.includeHiddenFiles = false
        let (withoutHidden, _, _) = try await collect(request(root, exclusions: noHidden))
        XCTAssertEqual(Set(withoutHidden.map(\.filename)), ["visible.txt"])
    }

    func testPackagesAreSingleItems() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.makeFolder("Root")
        try sandbox.write("Root/Tool.app/Contents/MacOS/tool", String(repeating: "a", count: 100))
        try sandbox.write("Root/Tool.app/Contents/Info.plist", String(repeating: "b", count: 50))

        let (observations, _, _) = try await collect(request(root))
        XCTAssertEqual(observations.count, 1)
        let app = try XCTUnwrap(observations.first)
        XCTAssertEqual(app.itemKind, .package)
        XCTAssertEqual(app.sizeBytes, 150)
        XCTAssertFalse(app.sizeIsEstimate)
    }

    func testSymbolicLinksAreRecordedButNotFollowed() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.makeFolder("Root")
        try sandbox.write("Root/Real/file.txt", "content")
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("Root/LinkToReal"), withDestinationPath: sandbox.path("Root/Real"))
        // A link back to an ancestor would loop forever if links were followed.
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("Root/Real/Loop"), withDestinationPath: root)

        let (observations, _, _) = try await collect(request(root))
        let paths = Set(observations.map(\.path))

        XCTAssertEqual(paths, [
            sandbox.path("Root/Real"), sandbox.path("Root/Real/file.txt"),
            sandbox.path("Root/LinkToReal"), sandbox.path("Root/Real/Loop"),
        ])
        let link = try XCTUnwrap(observations.first { $0.filename == "LinkToReal" })
        XCTAssertEqual(link.itemKind, .symlink)
        XCTAssertEqual(link.symlinkTarget, sandbox.path("Root/Real"))
    }

    func testSkippedSubtreesAreNotTraversed() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.makeFolder("Root")
        let nested = try sandbox.makeFolder("Root/Nested")
        try sandbox.write("Root/Nested/inner.txt", "x")
        try sandbox.write("Root/outer.txt", "x")

        let (observations, _, _) = try await collect(request(root, skipped: [nested]))
        XCTAssertEqual(Set(observations.map(\.filename)), ["Nested", "outer.txt"])
    }

    func testUnreadableFolderIsReportedAndDoesNotAbortScan() async throws {
        try XCTSkipIf(geteuid() == 0, "Permission checks do not apply to root")
        let sandbox = try TestSandbox()
        let root = try sandbox.makeFolder("Root")
        try sandbox.write("Root/Locked/secret.txt", "x")
        try sandbox.write("Root/open.txt", "x")
        chmod(sandbox.path("Root/Locked"), 0o000)
        defer { chmod(sandbox.path("Root/Locked"), 0o755) }

        let (observations, summary, issues) = try await collect(request(root))

        XCTAssertTrue(observations.contains { $0.filename == "open.txt" })
        XCTAssertTrue(observations.contains { $0.filename == "Locked" })
        XCTAssertEqual(summary.unreadableDirectories, [sandbox.path("Root/Locked")])
        XCTAssertEqual(issues.count, 1)
    }

    func testCancellationStopsScan() async throws {
        let sandbox = try TestSandbox()
        let root = try sandbox.makeFolder("Root")
        for index in 0..<50 {
            try sandbox.write("Root/D\(index)/f.txt", "x")
        }
        let task = Task {
            try await FileScanner().scan(self.request(root)) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }
}
