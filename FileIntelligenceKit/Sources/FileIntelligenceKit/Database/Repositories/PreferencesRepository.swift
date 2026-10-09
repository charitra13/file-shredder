import Foundation
import GRDB

/// Typed access to `user_preferences`. Values are stored as JSON.
public struct PreferencesRepository: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        let text = try? database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM user_preferences WHERE key = ?", arguments: [key])
        }
        return SQL.decodeJSON(type, from: text ?? nil)
    }

    public func setValue<T: Encodable>(_ value: T, forKey key: String) throws {
        guard let json = SQL.encodeJSON(value) else {
            throw FileIntelligenceError.invalidInput("The setting could not be saved.")
        }
        try database.writer.write { db in
            try PreferenceRecord(key: key, value: json, updatedAt: Date()).save(db)
        }
    }

    /// Current settings, falling back to defaults when none are stored or they cannot be decoded.
    public func loadSettings() -> AppSettings {
        value(AppSettings.self, forKey: AppSettings.storageKey) ?? AppSettings()
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try setValue(settings, forKey: AppSettings.storageKey)
    }
}
