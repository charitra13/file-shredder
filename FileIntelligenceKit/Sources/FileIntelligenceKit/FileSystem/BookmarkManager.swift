import Foundation

/// Creates and resolves persisted references to user-approved locations.
public protocol BookmarkManaging: Sendable {
    /// Returns bookmark data for `url`, or nil when this manager does not use bookmarks.
    func createBookmark(for url: URL) throws -> Data?
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
    @discardableResult
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Security-scoped bookmarks, required for persistent access from the App Sandbox.
public struct SecurityScopedBookmarkManager: BookmarkManaging {
    public init() {}

    public func createBookmark(for url: URL) throws -> Data? {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    @discardableResult
    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Uses plain paths. For tests and unsandboxed tooling only.
public struct PathOnlyBookmarkManager: BookmarkManaging {
    public init() {}

    public func createBookmark(for url: URL) throws -> Data? { nil }

    public func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        throw CocoaError(.fileReadUnknown)
    }

    @discardableResult
    public func startAccessing(_ url: URL) -> Bool { true }

    public func stopAccessing(_ url: URL) {}
}
