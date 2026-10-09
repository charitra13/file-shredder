import Foundation

public enum ProcessingStage: String, Sendable, CaseIterable {
    case metadata
    case classification
    case hashing
    case scoring

    public var displayName: String {
        switch self {
        case .metadata: return "Reading metadata"
        case .classification: return "Classifying"
        case .hashing: return "Checking for duplicates"
        case .scoring: return "Scoring review candidates"
        }
    }
}

public struct ProcessingProgress: Sendable, Equatable {
    public var stage: ProcessingStage
    public var completed: Int
    public var total: Int

    public init(stage: ProcessingStage, completed: Int, total: Int) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }

    public var fraction: Double? {
        total > 0 ? min(1, Double(completed) / Double(total)) : nil
    }
}

/// Post-scan processing, in dependency order. Each stage is incremental and only touches pending work,
/// except scoring, which is cheap and depends on facts (duplicates, project folders) that span files.
public struct ProcessingPipeline: Sendable {
    let database: AppDatabase
    let enricher: MetadataEnricher
    let classifier: ClassificationService
    let duplicates: DuplicateDetector
    let scorer: CleanupScorer
    let preferences: PreferencesRepository

    public init(
        database: AppDatabase,
        enricher: MetadataEnricher,
        classifier: ClassificationService,
        duplicates: DuplicateDetector,
        scorer: CleanupScorer,
        preferences: PreferencesRepository
    ) {
        self.database = database
        self.enricher = enricher
        self.classifier = classifier
        self.duplicates = duplicates
        self.scorer = scorer
        self.preferences = preferences
    }

    public func run(progress: @Sendable (ProcessingProgress) -> Void = { _ in }) async throws {
        let settings = preferences.loadSettings()
        try await enricher.enrichPending(progress: progress)
        try await classifier.classifyPending(progress: progress)
        try await duplicates.run(settings: settings.hashing, progress: progress)
        try await scorer.scoreAll(settings: settings.scoring, progress: progress)
    }
}
