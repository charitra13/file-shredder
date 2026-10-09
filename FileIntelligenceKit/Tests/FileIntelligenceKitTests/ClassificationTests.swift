import GRDB
import XCTest
@testable import FileIntelligenceKit

final class ClassificationEngineTests: XCTestCase {
    private let engine = ClassificationEngine()

    private func input(
        _ filename: String,
        uti: String? = nil,
        kind: ItemKind = .regular,
        size: Int64 = 1_000,
        signature: FormatSignature? = nil
    ) -> ClassificationInput {
        ClassificationInput(
            filename: filename,
            fileExtension: PathUtilities.fileExtension(of: filename),
            uti: uti,
            itemKind: kind,
            sizeBytes: size,
            signature: signature,
            path: "/Users/test/\(filename)"
        )
    }

    func testExtensionRules() {
        XCTAssertEqual(engine.classify(input("paper.pdf", signature: .pdf))?.categorySlug, "documents")
        XCTAssertEqual(engine.classify(input("budget.xlsx", signature: .zip))?.categorySlug, "spreadsheets")
        XCTAssertEqual(engine.classify(input("deck.key"))?.categorySlug, "presentations")
        XCTAssertEqual(engine.classify(input("Setup.dmg"))?.categorySlug, "installers")
        XCTAssertEqual(engine.classify(input("backup.zip", signature: .zip))?.categorySlug, "archives")
        XCTAssertEqual(engine.classify(input("logo.sketch"))?.categorySlug, "design-assets")
        XCTAssertEqual(engine.classify(input("Inter.ttf"))?.categorySlug, "fonts")
        XCTAssertEqual(engine.classify(input("data.parquet"))?.categorySlug, "datasets")
        XCTAssertEqual(engine.classify(input("app.sqlite", signature: .sqlite))?.categorySlug, "databases")
        XCTAssertEqual(engine.classify(input("config.yaml"))?.categorySlug, "configuration")
    }

    func testEveryResultHasSourceConfidenceAndExplanation() throws {
        let result = try XCTUnwrap(engine.classify(input("photo.jpg", signature: .jpeg)))
        XCTAssertEqual(result.categorySlug, "images")
        XCTAssertEqual(result.source, .builtInRule)
        XCTAssertGreaterThan(result.confidence, 0.5)
        XCTAssertFalse(result.explanation.isEmpty)
    }

    func testSourceCodeLanguageDetection() throws {
        let result = try XCTUnwrap(engine.classify(input("main.swift")))
        XCTAssertEqual(result.categorySlug, "source-code")
        XCTAssertEqual(result.language, "Swift")
        XCTAssertEqual(engine.classify(input("Makefile"))?.categorySlug, "source-code")
    }

    func testTemporaryPatterns() {
        XCTAssertEqual(engine.classify(input("movie.mp4.crdownload"))?.categorySlug, "temporary")
        XCTAssertEqual(engine.classify(input("~$Report.docx"))?.categorySlug, "temporary")
        XCTAssertEqual(engine.classify(input("notes.txt~"))?.categorySlug, "temporary")
    }

    func testFileWithoutExtensionUsesContentSignature() throws {
        let result = try XCTUnwrap(engine.classify(input("scan_0001", signature: .pdf)))
        XCTAssertEqual(result.categorySlug, "documents")
        XCTAssertTrue(result.explanation.contains("no extension"))
    }

    func testMismatchedExtensionIsClassifiedByContents() throws {
        let result = try XCTUnwrap(engine.classify(input("invoice.pdf", signature: .zip)))
        XCTAssertEqual(result.categorySlug, "archives")
        XCTAssertLessThanOrEqual(result.confidence, 0.6)
        XCTAssertTrue(result.explanation.contains("contents"))
    }

    func testUnknownTypesAreUnknownWithRationale() throws {
        let result = try XCTUnwrap(engine.classify(input("blob.zzqx", signature: .binary)))
        XCTAssertEqual(result.categorySlug, "unknown")
        XCTAssertEqual(result.confidence, 0)
        XCTAssertTrue(result.explanation.contains(".zzqx"))
    }

    func testPackagesAndLinksAndFolders() {
        XCTAssertEqual(engine.classify(input("Safari.app", uti: "com.apple.application-bundle", kind: .package))?.categorySlug, "applications")
        let link = engine.classify(input("shortcut", uti: "public.symlink", kind: .symlink))
        XCTAssertNotNil(link)
        XCTAssertNil(link?.categorySlug)
        XCTAssertNil(engine.classify(input("Folder", kind: .directory)))
    }

    func testJSONDependsOnSize() {
        XCTAssertEqual(engine.classify(input("settings.json", size: 2_000))?.categorySlug, "configuration")
        XCTAssertEqual(engine.classify(input("dump.json", size: 50_000_000))?.categorySlug, "datasets")
    }

    func testSemanticTagsUseWholeWordsOnly() throws {
        let invoice = try XCTUnwrap(engine.classify(input("Invoice_2024-03.pdf", signature: .pdf)))
        XCTAssertEqual(invoice.categorySlug, "documents", "Keywords never change the category on their own")
        XCTAssertEqual(invoice.suggestedTags, ["invoice-or-receipt"])
        let wallpaper = try XCTUnwrap(engine.classify(input("wallpaper.pdf", signature: .pdf)))
        XCTAssertEqual(wallpaper.suggestedTags, [])
        let camel = try XCTUnwrap(engine.classify(input("LectureNotesWeek3.pdf", signature: .pdf)))
        XCTAssertEqual(camel.suggestedTags, ["lecture-notes"])
    }

    func testUserRulesTakePrecedence() throws {
        let rule = ResolvedCategoryRule(
            matchKind: .fileExtension, pattern: "pdf", categorySlug: "reference",
            categoryName: "Reference Materials", origin: .manual
        )
        let custom = ClassificationEngine(rules: [rule])
        let result = try XCTUnwrap(custom.classify(input("manual.pdf", signature: .pdf)))
        XCTAssertEqual(result.categorySlug, "reference")
        XCTAssertEqual(result.source, .userRule)
        XCTAssertTrue(result.explanation.contains("your rule"))
    }

    func testSignatureDetection() {
        XCTAssertEqual(FormatSignature.detect(Array("%PDF-1.4".utf8)), .pdf)
        XCTAssertEqual(FormatSignature.detect([0x50, 0x4B, 0x03, 0x04, 0x14]), .zip)
        XCTAssertEqual(FormatSignature.detect([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), .png)
        XCTAssertEqual(FormatSignature.detect(Array("SQLite format 3".utf8) + [0x00, 0x10]), .sqlite)
        XCTAssertEqual(FormatSignature.detect(Array("plain words\n".utf8)), .plainText)
        XCTAssertEqual(FormatSignature.detect([0x00, 0x13, 0x37, 0x00, 0x99]), .binary)
        XCTAssertNil(FormatSignature.detect([]))
    }
}

final class ClassificationServiceTests: XCTestCase {
    func testPipelineClassifiesAndRecordsRationale() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/report.pdf", "%PDF-1.7\n fake pdf body")
        try sandbox.write("Root/README", "Read me")
        try sandbox.write("Root/mystery", data: Data([0x00, 0x01, 0x02, 0x03, 0xFF]))
        try await sandbox.scan(root)
        try await sandbox.process()

        let report = try XCTUnwrap(sandbox.record(at: "Root/report.pdf"))
        XCTAssertEqual(report.classificationSource, .builtInRule)
        XCTAssertNotNil(report.classificationExplanation)
        XCTAssertNotNil(report.classifiedAt)
        XCTAssertEqual(report.detectedSignature, FormatSignature.pdf.rawValue)

        let readme = try XCTUnwrap(sandbox.record(at: "Root/README"))
        let mystery = try XCTUnwrap(sandbox.record(at: "Root/mystery"))
        let slugs = try sandbox.database.reader.read { db in
            try Dictionary(uniqueKeysWithValues: FileCategory.fetchAll(db).map { ($0.id ?? -1, $0.slug) })
        }
        XCTAssertEqual(slugs[report.categoryId ?? -2], "documents")
        XCTAssertEqual(slugs[readme.categoryId ?? -2], "documents")
        XCTAssertEqual(slugs[mystery.categoryId ?? -2], "unknown")
    }

    func testUserClassificationSurvivesRescanAndChanges() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/thing.pdf", "%PDF-1.7 body")
        try await sandbox.scan(root)
        try await sandbox.process()
        let file = try XCTUnwrap(sandbox.record(at: "Root/thing.pdf"))
        let categories = try await sandbox.environment.categories.all()
        let reference = try XCTUnwrap(categories.first { $0.slug == "reference" })

        try await sandbox.environment.review.reclassify(fileIds: [XCTUnwrap(file.id)], categoryId: XCTUnwrap(reference.id))
        try sandbox.write("Root/thing.pdf", "%PDF-1.7 a different and longer body")
        try await sandbox.scan(root)
        try await sandbox.process()

        let after = try XCTUnwrap(sandbox.record(at: "Root/thing.pdf"))
        XCTAssertEqual(after.categoryId, reference.id)
        XCTAssertEqual(after.classificationSource, .user)
    }

    func testRepeatedCorrectionsCreateLearnedRuleThatCanBeReset() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        for index in 0..<4 {
            try sandbox.write("Root/model\(index).usdz", "x")
        }
        try await sandbox.scan(root)
        try await sandbox.process()
        let categories = try await sandbox.environment.categories.all()
        let reference = try XCTUnwrap(categories.first { $0.slug == "reference" })
        let ids = try (0..<3).map { try XCTUnwrap(sandbox.record(at: "Root/model\($0).usdz")?.id) }

        try await sandbox.environment.review.reclassify(fileIds: ids, categoryId: XCTUnwrap(reference.id))
        try await sandbox.process()

        let rules = try await sandbox.environment.categories.rules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.rule.origin, .learned)
        let fourth = try XCTUnwrap(sandbox.record(at: "Root/model3.usdz"))
        XCTAssertEqual(fourth.categoryId, reference.id)
        XCTAssertEqual(fourth.classificationSource, .learnedRule)

        let removed = try await sandbox.environment.maintenance.resetLearnedPreferences()
        XCTAssertEqual(removed, 1)
        try await sandbox.process()
        let reset = try XCTUnwrap(sandbox.record(at: "Root/model3.usdz"))
        XCTAssertEqual(reset.classificationSource, .builtInRule)
        XCTAssertEqual(try sandbox.record(at: "Root/model0.usdz")?.classificationSource, .user, "Your own choices are kept")
    }
}
