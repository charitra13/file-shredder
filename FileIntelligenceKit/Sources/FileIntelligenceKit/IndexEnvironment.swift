import Foundation

/// The composition root: builds every service on top of one database. Used by the app and by tests.
public final class IndexEnvironment: Sendable {
    public let database: AppDatabase
    public let registry: RootRegistry
    public let indexing: IndexingService
    public let files: FileQueryRepository
    public let stats: StatsRepository
    public let duplicates: DuplicateRepository
    public let activity: ActivityRepository
    public let categories: CategoryRepository
    public let preferences: PreferencesRepository
    public let review: ReviewService
    public let maintenance: MaintenanceService
    public let duplicateDetector: DuplicateDetector
    public let pipeline: ProcessingPipeline

    public init(
        database: AppDatabase,
        bookmarks: any BookmarkManaging,
        validation: RootValidationPolicy,
        conformance: TypeConformance = .system,
        scanner: FileScanner = FileScanner(),
        hasher: ContentHasher = ContentHasher()
    ) {
        self.database = database
        let preferences = PreferencesRepository(database: database)
        let classifier = ClassificationService(database: database, conformance: conformance)
        let scorer = CleanupScorer(database: database)
        let detector = DuplicateDetector(database: database, hasher: hasher)
        let pipeline = ProcessingPipeline(
            database: database,
            enricher: MetadataEnricher(database: database),
            classifier: classifier,
            duplicates: detector,
            scorer: scorer,
            preferences: preferences
        )
        let registry = RootRegistry(database: database, bookmarks: bookmarks, validation: validation)

        self.preferences = preferences
        self.registry = registry
        self.pipeline = pipeline
        self.duplicateDetector = detector
        self.indexing = IndexingService(
            registry: registry,
            scanner: scanner,
            writer: IndexWriter(database: database),
            pipeline: pipeline
        )
        self.files = FileQueryRepository(database: database)
        self.stats = StatsRepository(database: database, preferences: preferences)
        self.duplicates = DuplicateRepository(database: database)
        self.activity = ActivityRepository(database: database)
        self.categories = CategoryRepository(database: database)
        self.review = ReviewService(database: database, scorer: scorer, preferences: preferences)
        self.maintenance = MaintenanceService(database: database, classifier: classifier)
    }

    /// The production configuration: on-disk index, security-scoped bookmarks, standard protections.
    public static func production() throws -> IndexEnvironment {
        let database = try AppDatabase.open(at: AppDatabase.defaultLocation())
        try database.recoverInterruptedScans()
        return IndexEnvironment(
            database: database,
            bookmarks: SecurityScopedBookmarkManager(),
            validation: .standard
        )
    }
}
