import Foundation

/// Decides which folders may be added as indexed locations.
///
/// The app never indexes the whole filesystem or system folders, even when macOS would allow reading them.
public struct RootValidationPolicy: Sendable {
    public var protectedPrefixes: [String]

    public init(protectedPrefixes: [String]) {
        self.protectedPrefixes = protectedPrefixes
    }

    public static var standard: RootValidationPolicy {
        let home = PathUtilities.realHomeDirectory
        return RootValidationPolicy(protectedPrefixes: [
            "/System", "/Library", "/private", "/usr", "/bin", "/sbin",
            "/dev", "/cores", "/etc", "/var", "/tmp", "/opt",
            home + "/Library",
        ])
    }

    /// Allows any folder except "/". Intended for tests that index temporary directories.
    public static let permissive = RootValidationPolicy(protectedPrefixes: [])

    public func validate(_ path: String) throws {
        if path == "/" {
            throw FileIntelligenceError.protectedLocation(path)
        }
        for prefix in protectedPrefixes where PathUtilities.isPath(path, inside: prefix) {
            throw FileIntelligenceError.protectedLocation(path)
        }
    }
}
