import Darwin
import Foundation

public enum PathUtilities {
    /// Resolves symbolic links and relative components with `realpath(3)`.
    ///
    /// Unlike `NSString.resolvingSymlinksInPath`, this never strips the `/private` prefix,
    /// so paths compare consistently with those produced while scanning.
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return normalized(path)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Standardises a path lexically and removes any trailing slash.
    public static func normalized(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result.isEmpty ? "/" : result
    }

    /// True when `path` equals `base` or lies anywhere beneath it.
    public static func isPath(_ path: String, inside base: String) -> Bool {
        if path == base { return true }
        return isPath(path, strictlyInside: base)
    }

    /// True when `path` lies beneath `base` (and is not `base` itself).
    public static func isPath(_ path: String, strictlyInside base: String) -> Bool {
        if base == "/" { return path != "/" && path.hasPrefix("/") }
        return path.hasPrefix(base + "/")
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    public static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Lowercased extension without the dot, or nil for names without one (including dotfiles like `.env`).
    public static func fileExtension(of name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        // ".env" has no extension; "archive.tar.gz" has "gz".
        if name.hasPrefix(".") && name.dropFirst().firstIndex(of: ".") == nil { return nil }
        return ext.lowercased()
    }

    /// Ancestors from the immediate parent up to "/".
    public static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = path
        while current != "/" && !current.isEmpty {
            current = parent(of: current)
            result.append(current)
        }
        return result
    }

    public static func isReachableDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The real home directory, even inside the App Sandbox where `NSHomeDirectory()` points at the container.
    public static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }

    /// A short human-readable form of a path that abbreviates the home directory as "~".
    public static func abbreviated(_ path: String) -> String {
        let home = realHomeDirectory
        if path == home { return "~" }
        if isPath(path, strictlyInside: home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
