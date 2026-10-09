import Foundation

/// Case-insensitive matcher compiled from an `ExclusionConfig`.
struct ExclusionPolicy: Sendable {
    let excludedDirectoryNames: Set<String>
    let opaqueDirectoryNames: Set<String>
    let excludedFileNames: Set<String>
    let includeHiddenFiles: Bool
    let descendIntoPackages: Bool

    init(_ config: ExclusionConfig) {
        excludedDirectoryNames = Set(config.excludedDirectoryNames.map { $0.lowercased() })
        opaqueDirectoryNames = Set(config.opaqueDirectoryNames.map { $0.lowercased() })
        excludedFileNames = Set(config.excludedFileNames.map { $0.lowercased() })
        includeHiddenFiles = config.includeHiddenFiles
        descendIntoPackages = config.descendIntoPackages
    }

    func isExcludedDirectory(_ name: String) -> Bool {
        excludedDirectoryNames.contains(name.lowercased())
    }

    func isOpaqueDirectory(_ name: String) -> Bool {
        opaqueDirectoryNames.contains(name.lowercased())
    }

    func isExcludedFile(_ name: String) -> Bool {
        excludedFileNames.contains(name.lowercased())
    }
}
