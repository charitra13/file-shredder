import XCTest
@testable import FileIntelligenceKit

final class FileQueryTests: XCTestCase {
    private func makeLibrary() async throws -> (TestSandbox, ScanRoot) {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Library")
        try sandbox.write("Library/Networks/computer-networks.pdf", "%PDF-1.7 " + String(repeating: "n", count: 2_000))
        try sandbox.write("Library/Networks/notes.md", "# notes")
        try sandbox.write("Library/Archive/big.zip", data: Data([0x50, 0x4B, 0x03, 0x04]) + .repeating(1, count: 50_000))
        try sandbox.write("Library/100% done_v2.txt", "x")
        try sandbox.write("Library/mystery", data: Data([0x00, 0xFE]))
        try await sandbox.scan(root)
        try await sandbox.process()
        return (sandbox, root)
    }

    func testTextSearchMatchesNameAndFolder() async throws {
        let (sandbox, _) = try await makeLibrary()
        let files = sandbox.environment.files

        let byName = try await files.fetchPage(FileQuery(text: "computer"), offset: 0, limit: 50)
        XCTAssertEqual(byName.map(\.filename), ["computer-networks.pdf"])

        let byFolder = try await files.fetchPage(FileQuery(text: "networks", itemKinds: [.regular]), offset: 0, limit: 50)
        XCTAssertEqual(Set(byFolder.map(\.filename)), ["computer-networks.pdf", "notes.md"])

        let multiTerm = try await files.fetchPage(FileQuery(text: "networks notes"), offset: 0, limit: 50)
        XCTAssertEqual(multiTerm.map(\.filename), ["notes.md"])
    }

    func testLikeWildcardsAreEscaped() async throws {
        let (sandbox, _) = try await makeLibrary()
        let percent = try await sandbox.environment.files.fetchPage(FileQuery(text: "100%"), offset: 0, limit: 50)
        XCTAssertEqual(percent.map(\.filename), ["100% done_v2.txt"])
        let underscore = try await sandbox.environment.files.fetchPage(FileQuery(text: "e_v"), offset: 0, limit: 50)
        XCTAssertEqual(underscore.map(\.filename), ["100% done_v2.txt"])
        let none = try await sandbox.environment.files.fetchPage(FileQuery(text: "_x_"), offset: 0, limit: 50)
        XCTAssertTrue(none.isEmpty)
    }

    func testCategorySizeAndUnclassifiedFilters() async throws {
        let (sandbox, _) = try await makeLibrary()
        let files = sandbox.environment.files
        let categories = try await sandbox.environment.categories.all()
        let archives = try XCTUnwrap(categories.first { $0.slug == "archives" })

        let archiveResults = try await files.fetchPage(FileQuery(categoryId: archives.id), offset: 0, limit: 50)
        XCTAssertEqual(archiveResults.map(\.filename), ["big.zip"])

        let large = try await files.fetchPage(FileQuery(minimumSize: 10_000), offset: 0, limit: 50)
        XCTAssertEqual(large.map(\.filename), ["big.zip"])

        let unclassified = try await files.fetchPage(FileQuery(unclassifiedOnly: true), offset: 0, limit: 50)
        XCTAssertEqual(unclassified.map(\.filename), ["mystery"])
    }

    func testSortingPaginationAndSummary() async throws {
        let (sandbox, _) = try await makeLibrary()
        let files = sandbox.environment.files
        let query = FileQuery(itemKinds: [.regular], sortField: .size, ascending: false)

        let summary = try await files.summary(query)
        XCTAssertEqual(summary.count, 5)

        let firstPage = try await files.fetchPage(query, offset: 0, limit: 2)
        let secondPage = try await files.fetchPage(query, offset: 2, limit: 2)
        let thirdPage = try await files.fetchPage(query, offset: 4, limit: 2)
        XCTAssertEqual(firstPage.first?.filename, "big.zip")
        XCTAssertEqual(firstPage.count + secondPage.count + thirdPage.count, 5)
        XCTAssertTrue(Set(firstPage.map(\.id)).isDisjoint(with: secondPage.map(\.id)))
        let sizes = (firstPage + secondPage + thirdPage).map(\.sizeBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }

    func testMissingFilesAreHiddenByDefault() async throws {
        let (sandbox, root) = try await makeLibrary()
        try FileManager.default.removeItem(atPath: sandbox.path("Library/Networks/notes.md"))
        try await sandbox.scan(root)

        let visible = try await sandbox.environment.files.fetchPage(FileQuery(text: "notes"), offset: 0, limit: 50)
        XCTAssertTrue(visible.isEmpty)
        let all = try await sandbox.environment.files.fetchPage(FileQuery(text: "notes", availability: nil), offset: 0, limit: 50)
        XCTAssertEqual(all.first?.availability, .missing)
    }

    func testOverviewStatsComeFromTheDatabase() async throws {
        let (sandbox, _) = try await makeLibrary()
        let stats = try await sandbox.environment.stats.overview()
        XCTAssertEqual(stats.totalItems, 5)
        XCTAssertEqual(stats.totalFolders, 2)
        XCTAssertEqual(stats.locationCount, 1)
        XCTAssertEqual(stats.unclassifiedItems, 1)
        XCTAssertEqual(stats.pendingProcessing, 0)
    }
}
