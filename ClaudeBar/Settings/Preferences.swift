import Foundation

/// JSON-in-UserDefaults storage for the app's preferences. Each preference is a
/// `Codable` value, so one can grow fields without a defaults migration.
enum Preferences {
    static func read<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writing nil clears the preference.
    static func write<Value: Encodable>(_ value: Value?, key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}
