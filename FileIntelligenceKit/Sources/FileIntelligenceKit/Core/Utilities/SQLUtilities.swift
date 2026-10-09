import Foundation
import GRDB

enum SQL {
    /// SQLite's default host-parameter limit is generous on macOS, but chunks keep statements small.
    static let chunkSize = 500

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Escapes `%`, `_` and `\` for use with `LIKE ... ESCAPE '\'`.
    static func escapeLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Bounds such that `path >= lower AND path < upper` selects every path strictly inside `directory`.
    ///
    /// This uses the unique index on `files.path` (BINARY collation), unlike `LIKE` or `substr`.
    /// It works because "0" is the character immediately after "/".
    static func descendantRange(of directory: String) -> (lower: String, upper: String) {
        let base = directory == "/" ? "" : directory
        return (base + "/", base + "0")
    }

    /// Runs `body` once per chunk of ids with a matching placeholder list.
    static func forEachChunk(
        of ids: [Int64],
        _ body: (_ chunk: [Int64], _ placeholders: String) throws -> Void
    ) rethrows {
        var start = 0
        while start < ids.count {
            let end = min(start + chunkSize, ids.count)
            let chunk = Array(ids[start..<end])
            try body(chunk, placeholders(chunk.count))
            start = end
        }
    }

    static func arguments(_ values: [(any DatabaseValueConvertible)?]) -> StatementArguments {
        StatementArguments(values)
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension Optional where Wrapped == Row {
    /// Reads a non-null integer aggregate, or zero when the row is absent.
    func int(_ column: String) -> Int {
        map { $0[column] as Int } ?? 0
    }

    func int64(_ column: String) -> Int64 {
        map { $0[column] as Int64 } ?? 0
    }
}
