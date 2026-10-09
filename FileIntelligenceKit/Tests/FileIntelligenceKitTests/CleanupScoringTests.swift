import XCTest
@testable import FileIntelligenceKit

final class CleanupScoringTests: XCTestCase {
    private let settings = CleanupScoringSettings()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(
        slug: String?,
        size: Int64 = 1_000,
        createdDaysAgo: Double = 1,
        modifiedDaysAgo: Double = 1,
        review: ReviewStatus = .unreviewed,
        duplicate: DuplicateContext? = nil,
        project: Bool = false,
        sibling: Bool = false,
        kind: ItemKind = .regular,
        availability: Availability = .available
    ) -> ScoringInput {
        ScoringInput(
            filename: "file",
            itemKind: kind,
            availability: availability,
            reviewStatus: review,
            categorySlug: slug,
            sizeBytes: size,
            createdAt: now.addingTimeInterval(-createdDaysAgo * 86_400),
            modifiedAt: now.addingTimeInterval(-modifiedDaysAgo * 86_400),
            firstIndexedAt: now,
            duplicate: duplicate,
            isInsideProject: project,
            hasSiblingFolderWithSameName: sibling
        )
    }

    private func codes(_ outcome: ScoringOutcome) -> Set<String> {
        Set(outcome.reasons.map(\.code))
    }

    func testNonReferenceDuplicateIsExplained() {
        let duplicate = DuplicateContext(isReferenceCopy: false, copyCount: 3, referencePath: "/a", referenceInSameFolder: false)
        let outcome = CleanupScorer.evaluate(input(slug: "documents", duplicate: duplicate), settings: settings, now: now)
        XCTAssertEqual(outcome.priority, settings.weights.exactDuplicate)
        XCTAssertEqual(outcome.reasons.first?.message, "An identical copy exists in another indexed location (3 copies in total).")
    }

    func testReferenceCopyGetsNoDuplicateReason() {
        let duplicate = DuplicateContext(isReferenceCopy: true, copyCount: 2, referencePath: nil, referenceInSameFolder: false)
        let outcome = CleanupScorer.evaluate(input(slug: "documents", duplicate: duplicate), settings: settings, now: now)
        XCTAssertEqual(outcome.priority, 0)
        XCTAssertTrue(outcome.reasons.isEmpty)
    }

    func testExplicitKeepAndIgnoreSuppressRecommendations() {
        let duplicate = DuplicateContext(isReferenceCopy: false, copyCount: 2, referencePath: nil, referenceInSameFolder: true)
        for status in [ReviewStatus.keep, .ignored] {
            let outcome = CleanupScorer.evaluate(
                input(slug: "temporary", size: 5_000_000_000, review: status, duplicate: duplicate),
                settings: settings, now: now
            )
            XCTAssertEqual(outcome.priority, 0)
            XCTAssertTrue(outcome.reasons.isEmpty)
        }
        let later = CleanupScorer.evaluate(input(slug: "temporary", review: .reviewLater), settings: settings, now: now)
        XCTAssertGreaterThan(later.priority ?? 0, 0, "Review Later keeps the recommendation")
    }

    func testInstallerAgeMatters() {
        let fresh = CleanupScorer.evaluate(input(slug: "installers", createdDaysAgo: 2), settings: settings, now: now)
        XCTAssertEqual(fresh.priority, 0)
        let old = CleanupScorer.evaluate(input(slug: "installers", createdDaysAgo: 90), settings: settings, now: now)
        XCTAssertTrue(codes(old).contains("oldInstaller"))
        XCTAssertEqual(old.priority, settings.weights.oldInstaller)
    }

    func testOldFileAloneIsNotACandidate() {
        let outcome = CleanupScorer.evaluate(input(slug: "documents", modifiedDaysAgo: 800), settings: settings, now: now)
        XCTAssertTrue(codes(outcome).contains("notModifiedRecently"))
        XCTAssertLessThan(outcome.priority ?? 0, settings.minimumCandidatePriority)
        XCTAssertTrue(outcome.reasons.first?.message.contains("does not mean it is unused") ?? false)
    }

    func testScoreIsClampedTo100() {
        let duplicate = DuplicateContext(isReferenceCopy: false, copyCount: 2, referencePath: nil, referenceInSameFolder: true)
        let outcome = CleanupScorer.evaluate(
            input(slug: "archives", size: 10_000_000_000, modifiedDaysAgo: 900, duplicate: duplicate, sibling: true),
            settings: settings, now: now
        )
        XCTAssertEqual(outcome.priority, 100)
        XCTAssertTrue(codes(outcome).isSuperset(of: ["exactDuplicate", "veryLargeFile", "largeArchive", "archiveAlreadyExtracted"]))
        XCTAssertEqual(outcome.reasons.map(\.weight), outcome.reasons.map(\.weight).sorted(by: >))
    }

    func testProjectAndSourcePenaltiesLowerPriority() {
        let duplicate = DuplicateContext(isReferenceCopy: false, copyCount: 2, referencePath: nil, referenceInSameFolder: false)
        let plain = CleanupScorer.evaluate(input(slug: "source-code", duplicate: duplicate), settings: settings, now: now)
        let inProject = CleanupScorer.evaluate(input(slug: "source-code", duplicate: duplicate, project: true), settings: settings, now: now)
        XCTAssertLessThan(inProject.priority ?? 0, plain.priority ?? 0)
        XCTAssertTrue(codes(inProject).contains("projectMember"))
        XCTAssertEqual(inProject.priority, 0)
    }

    func testIneligibleItemsHaveNoScore() {
        XCTAssertNil(CleanupScorer.evaluate(input(slug: nil, kind: .directory), settings: settings, now: now).priority)
        XCTAssertNil(CleanupScorer.evaluate(input(slug: nil, kind: .symlink), settings: settings, now: now).priority)
        XCTAssertNil(CleanupScorer.evaluate(input(slug: "temporary", availability: .missing), settings: settings, now: now).priority)
    }

    func testArchiveStem() {
        XCTAssertEqual(CleanupScorer.archiveStem("photos.tar.gz"), "photos")
        XCTAssertEqual(CleanupScorer.archiveStem("Project.zip"), "Project")
    }

    // MARK: - Persisted behaviour

    func testKeepDecisionPersistsAcrossRescansAndSuppressesScore() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/movie.mp4.crdownload", "partial")
        try await sandbox.scan(root)
        try await sandbox.process()
        let before = try XCTUnwrap(sandbox.record(at: "Root/movie.mp4.crdownload"))
        XCTAssertGreaterThanOrEqual(before.cleanupPriority ?? 0, 25)
        XCTAssertEqual(before.cleanupReasons?.first?.code, "temporaryFile")

        try await sandbox.setReviewStatus(.keep, at: "Root/movie.mp4.crdownload")
        XCTAssertEqual(try sandbox.record(at: "Root/movie.mp4.crdownload")?.cleanupPriority, 0)

        try await sandbox.scan(root)
        try await sandbox.process()
        let after = try XCTUnwrap(sandbox.record(at: "Root/movie.mp4.crdownload"))
        XCTAssertEqual(after.reviewStatus, .keep)
        XCTAssertEqual(after.cleanupPriority, 0)
        XCTAssertEqual(try sandbox.count("SELECT COUNT(*) FROM file_actions WHERE action_type = 'keep'"), 1)
    }

    func testArchiveNextToExtractedFolderIsRelated() async throws {
        let sandbox = try TestSandbox()
        let root = try await sandbox.addRoot("Root")
        try sandbox.write("Root/Photos.zip", data: Data([0x50, 0x4B, 0x03, 0x04, 0x00]))
        try sandbox.write("Root/Photos/img.txt", "x")
        try await sandbox.scan(root)
        try await sandbox.process()

        let archive = try XCTUnwrap(sandbox.record(at: "Root/Photos.zip"))
        XCTAssertTrue(archive.cleanupReasons?.contains { $0.code == "archiveAlreadyExtracted" } ?? false)
        let detail = try await sandbox.environment.files.detail(fileId: XCTUnwrap(archive.id))
        XCTAssertEqual(detail?.relationships.first?.kind, .archiveExtractedFolder)
        XCTAssertEqual(detail?.relationships.first?.isVerified, false, "Inferred relationships are labelled as such")
    }
}
