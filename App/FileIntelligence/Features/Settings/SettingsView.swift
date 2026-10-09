import FileIntelligenceKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings()
    @State private var hasLoaded = false
    @State private var excludedFolders = ""
    @State private var opaqueFolders = ""
    @State private var rules: [CategoryRuleSummary] = []
    @State private var categories: [FileCategory] = []
    @State private var newRuleKind: RuleMatchKind = .fileExtension
    @State private var newRulePattern = ""
    @State private var newRuleCategoryId: Int64?
    @State private var maintenanceMessage: String?
    @State private var isWorking = false

    private static let megabyte: Int64 = 1_000_000
    private let largeFileOptions: [Int64] = [100, 250, 500, 1_000, 2_000, 5_000].map { $0 * megabyte }
    private let intervalOptions = [0, 1, 3, 6, 12, 24]

    var body: some View {
        Form {
            indexingSection
            scoringSection
            rulesSection
            maintenanceSection
            privacySection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .disabled(!hasLoaded)
        .task {
            draft = model.settings
            excludedFolders = draft.defaultExclusions.excludedDirectoryNames.joined(separator: ", ")
            opaqueFolders = draft.defaultExclusions.opaqueDirectoryNames.joined(separator: ", ")
            hasLoaded = true
            await loadRules()
        }
        .onChange(of: draft) { _, newValue in
            guard hasLoaded else { return }
            model.updateSettings(newValue)
        }
    }

    // MARK: - Indexing

    private var indexingSection: some View {
        Section {
            Toggle("Watch indexed locations for changes", isOn: $draft.monitorFileSystemChanges)
            Picker("Full reconciliation scan", selection: $draft.reconciliationIntervalHours) {
                ForEach(intervalOptions, id: \.self) { hours in
                    Text(hours == 0 ? "Only when I ask" : (hours == 1 ? "Every hour" : "Every \(hours) hours")).tag(hours)
                }
            }
            Toggle("Include hidden files in new locations", isOn: $draft.defaultExclusions.includeHiddenFiles)
            TextField("Skipped folders", text: $excludedFolders, prompt: Text(".Trash, node_modules"))
                .onSubmit { commitFolderLists() }
            TextField("Folders counted but not opened", text: $opaqueFolders, prompt: Text(".git"))
                .onSubmit { commitFolderLists() }
            HStack {
                Button("Save Folder Rules") { commitFolderLists() }
                Button("Apply to All Locations") {
                    commitFolderLists()
                    model.applyDefaultExclusionsToAllLocations()
                }
                .help("Use these rules for every indexed location and rescan them")
            }
        } header: {
            Text("Indexing")
        } footer: {
            Text("Change watching makes updates quick while the app is open. Reconciliation scans catch anything missed, for example changes made while the app was closed. Folder names are separated by commas.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commitFolderLists() {
        func parse(_ text: String) -> [String] {
            text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        draft.defaultExclusions.excludedDirectoryNames = parse(excludedFolders)
        draft.defaultExclusions.opaqueDirectoryNames = parse(opaqueFolders)
    }

    // MARK: - Scoring

    private var scoringSection: some View {
        Section {
            LabeledContent("Show as review candidate from priority") {
                Stepper(value: $draft.scoring.minimumCandidatePriority, in: 5...90, step: 5) {
                    Text("\(draft.scoring.minimumCandidatePriority)").monospacedDigit()
                }
            }
            Picker("Large file threshold", selection: $draft.scoring.largeFileThreshold) {
                ForEach(largeFileOptions, id: \.self) { value in
                    Text(Format.bytes(value)).tag(value)
                }
            }
            LabeledContent("Flag installers older than") {
                Stepper(value: $draft.scoring.installerAgeDays, in: 7...365, step: 7) {
                    Text("\(draft.scoring.installerAgeDays) days").monospacedDigit()
                }
            }
            LabeledContent("Note files unmodified for") {
                Stepper(value: $draft.scoring.staleAgeDays, in: 90...1_825, step: 90) {
                    Text("\(draft.scoring.staleAgeDays) days").monospacedDigit()
                }
            }
            DisclosureGroup("Signal weights") {
                WeightSlider(title: "Identical copy elsewhere", value: $draft.scoring.weights.exactDuplicate)
                WeightSlider(title: "Temporary or partial file", value: $draft.scoring.weights.temporaryFile)
                WeightSlider(title: "Old installer", value: $draft.scoring.weights.oldInstaller)
                WeightSlider(title: "Large file", value: $draft.scoring.weights.largeFile)
                WeightSlider(title: "Very large file", value: $draft.scoring.weights.veryLargeFile)
                WeightSlider(title: "Large archive", value: $draft.scoring.weights.largeArchive)
                WeightSlider(title: "Archive possibly extracted", value: $draft.scoring.weights.archiveAlreadyExtracted)
                WeightSlider(title: "Not classified", value: $draft.scoring.weights.unclassified)
                WeightSlider(title: "Not modified recently", value: $draft.scoring.weights.notModifiedRecently)
                WeightSlider(title: "Inside a project (lowers)", value: $draft.scoring.weights.projectMemberPenalty)
                WeightSlider(title: "Code, config or database (lowers)", value: $draft.scoring.weights.sourceOrConfigPenalty)
                Button("Restore Default Weights") {
                    draft.scoring.weights = CleanupScoringSettings.Weights()
                }
            }
        } header: {
            Text("Cleanup Suggestions")
        } footer: {
            PriorityDisclaimer()
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section {
            if rules.isEmpty {
                Text("No rules yet. Rules you add here, or that are learned from repeated corrections, are applied before the built-in rules.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { summary in
                HStack {
                    Toggle(isOn: Binding(
                        get: { summary.rule.isEnabled },
                        set: { enabled in runRuleChange { try await model.environment.categories.setRuleEnabled(enabled, ruleId: summary.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(summary.rule.matchKind.displayName) “\(summary.rule.pattern)” → \(summary.categoryName)")
                            if summary.rule.origin == .learned {
                                Text(summary.rule.note ?? "Learned from your corrections")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        runRuleChange { try await model.environment.categories.deleteRule(ruleId: summary.id) }
                    } label: {
                        Label("Delete Rule", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Picker("Match", selection: $newRuleKind) {
                    ForEach(RuleMatchKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Pattern", text: $newRulePattern, prompt: Text(newRuleKind == .fileExtension ? "pdf" : "invoice"))
                Picker("Category", selection: $newRuleCategoryId) {
                    Text("Choose Category").tag(Int64?.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add Rule") {
                    guard let categoryId = newRuleCategoryId else { return }
                    let kind = newRuleKind
                    let pattern = newRulePattern
                    runRuleChange {
                        try await model.environment.categories.addRule(matchKind: kind, pattern: pattern, categoryId: categoryId)
                    }
                    newRulePattern = ""
                }
                .disabled(newRuleCategoryId == nil || newRulePattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Category Rules")
        } footer: {
            Text("Files you categorise yourself are never changed by rules.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadRules() async {
        let repository = model.environment.categories
        rules = (try? await repository.rules()) ?? []
        categories = (try? await repository.all()) ?? []
    }

    private func runRuleChange(_ change: @escaping @MainActor @Sendable () async throws -> Void) {
        Task {
            do {
                try await change()
                await loadRules()
                model.processNow()
            } catch {
                maintenanceMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        Section {
            maintenanceButton("Process Pending Items Now") {
                model.processNow()
                return "Processing started."
            }
            maintenanceButton("Recalculate Automatic Categories") {
                try model.environment.maintenance.reclassifyAutomaticCategories()
                model.processNow()
                return "Automatic categories will be recalculated. Your own choices are kept."
            }
            maintenanceButton("Verify Duplicates Again") {
                try await model.environment.maintenance.resetDuplicateDetection()
                model.processNow()
                return "Duplicates will be re-verified from disk."
            }
            maintenanceButton("Remove Missing Items from Index") {
                let removed = try await model.environment.maintenance.removeMissingFromIndex()
                return "Removed \(removed.formatted()) missing items from the index."
            }
            maintenanceButton("Reset Learned Preferences") {
                let removed = try await model.environment.maintenance.resetLearnedPreferences()
                await loadRules()
                model.processNow()
                return "Removed \(removed.formatted()) learned rules."
            }
            maintenanceButton("Check Index Integrity") {
                let result = try await model.environment.maintenance.integrityCheck()
                return result == "ok" ? "The index is healthy." : "Integrity check reported: \(result)"
            }
            maintenanceButton("Compact Index") {
                try await model.environment.maintenance.compact()
                return "The index file was compacted."
            }
            if let maintenanceMessage {
                Text(maintenanceMessage)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Index Maintenance")
        } footer: {
            Text("Maintenance changes only the index. Files on disk are never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func maintenanceButton(_ title: String, action: @escaping @MainActor @Sendable () async throws -> String) -> some View {
        Button(title) {
            isWorking = true
            Task {
                do {
                    maintenanceMessage = try await action()
                } catch {
                    maintenanceMessage = error.localizedDescription
                }
                isWorking = false
                model.revision += 1
            }
        }
        .disabled(isWorking)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Text("File Intelligence works entirely on this Mac. It has no account, no telemetry and no network features. Filenames, paths, metadata, contents and hashes never leave your computer.")
                .fixedSize(horizontal: false, vertical: true)
            Text("It reads only the locations you add. Removing a location removes it from the index; your files are not touched. Files are never opened to run them, and the app never deletes files.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WeightSlider: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(
                    value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                    in: 0...60,
                    step: 5
                )
                .frame(width: 160)
                Text("\(value)")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }
}
