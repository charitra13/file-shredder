import GRDB
import XCTest
@testable import FileIntelligenceKit

final class DatabaseTests: XCTestCase {
    func testMigrationCreatesAllTables() throws {
        let sandbox = try TestSandbox()
        let tables = try sandbox.database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in [
            "scan_roots", "files", "categories", "file_tags", "file_metadata", "extracted_content",
            "file_actions", "scan_runs", "scan_issues", "duplicate_groups", "file_relationships",
            "category_rules", "user_preferences",
        ] {
            XCTAssertTrue(tables.contains(table), "Missing table \(table)")
        }
    }

    func testReopeningExistingDatabaseKeepsData() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "hello")
        try await sandbox.scan(root)

        let url = URL(fileURLWithPath: sandbox.path("index.sqlite"))
        let reopened = try AppDatabase.open(at: url)
        let count = try await reopened.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE filename = 'a.txt'") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testSeededCategoriesIncludeTechnicalAndNestedSemanticCategories() async throws {
        let sandbox = try TestSandbox()
        let categories = try await sandbox.environment.categories.all()
        let bySlug = Dictionary(uniqueKeysWithValues: categories.map { ($0.slug, $0) })
        for slug in ["documents", "images", "installers", "temporary", "unknown", "source-code"] {
            XCTAssertNotNil(bySlug[slug], "Missing category \(slug)")
        }
        let documents = try XCTUnwrap(bySlug["documents"])
        XCTAssertEqual(bySlug["invoices-receipts"]?.parentId, documents.id)
        XCTAssertEqual(bySlug["invoices-receipts"]?.kind, .semantic)
    }

    func testRemovingRootCascadesToItsFilesButKeepsActionLog() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/a.txt", "hello")
        try await sandbox.scan(root)
        try await sandbox.setReviewStatus(.keep, at: "Root/a.txt")

        try await sandbox.environment.registry.removeRoot(id: XCTUnwrap(root.id))

        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM files"), 0)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM file_actions WHERE file_id IS NULL"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path("Root/a.txt")), "Removing a location must not delete files")
    }

    func testSettingsRoundTripAndDefaults() throws {
        let sandbox = try TestSandbox()
        let preferences = sandbox.environment.preferences
        XCTAssertEqual(preferences.loadSettings(), AppSettings())

        var settings = AppSettings()
        settings.scoring.minimumCandidatePriority = 42
        settings.reconciliationIntervalHours = 0
        try preferences.saveSettings(settings)
        XCTAssertEqual(preferences.loadSettings(), settings)
    }

    func testRecoverInterruptedScansMarksRunningRunsInterrupted() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        let writer = IndexWriter(database: sandbox.database)
        let runId = try writer.beginRun(rootId: XCTUnwrap(root.id), scope: .full(rootPath: root.path), now: Date())

        let recovered = try sandbox.database.recoverInterruptedScans()

        XCTAssertEqual(recovered, 1)
        let state = try await sandbox.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM scan_runs WHERE id = ?", arguments: [runId])
        }
        XCTAssertEqual(state, ScanRunState.interrupted.rawValue)
        let rootState = try await sandbox.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT scan_state FROM scan_roots WHERE id = ?", arguments: [root.id])
        }
        XCTAssertEqual(rootState, RootScanState.interrupted.rawValue)
    }

    func testDescendantRangeMatchesOnlyStrictDescendants() throws {
        let range = SQL.descendantRange(of: "/a/b")
        func inside(_ path: String) -> Bool { path >= range.lower && path < range.upper }
        XCTAssertTrue(inside("/a/b/c"))
        XCTAssertTrue(inside("/a/b/c/d.txt"))
        XCTAssertFalse(inside("/a/b"))
        XCTAssertFalse(inside("/a/bc"))
        XCTAssertFalse(inside("/a/b-c"))
        XCTAssertFalse(inside("/a/b0"))
    }
}
