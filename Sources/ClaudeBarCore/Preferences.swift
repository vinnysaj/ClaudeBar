import Foundation

/// JSON storage for the app's preferences. Each preference is a `Codable` value,
/// so one can grow fields without a migration. On the Mac they live in
/// UserDefaults; on Linux in a settings file beside ClaudeBar's other files.
public enum Preferences {
    public static func read<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = self.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writing nil clears the preference.
    public static func write<Value: Encodable>(_ value: Value?, key: String) {
        self.setData(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    #if os(macOS)
    private static func data(forKey key: String) -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    private static func setData(_ data: Data?, forKey key: String) {
        UserDefaults.standard.set(data, forKey: key)
    }
    #else
    private static let lock = NSLock()

    private static var fileURL: URL {
        AppPaths.support.appendingPathComponent("settings.json")
    }

    private static func data(forKey key: String) -> Data? {
        self.lock.withLock {
            self.load()[key].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
        }
    }

    /// Each preference sits in the file as the JSON it encodes to, so the file
    /// reads as plain settings.
    private static func setData(_ data: Data?, forKey key: String) {
        self.lock.withLock {
            var values = self.load()
            values[key] = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
            do {
                try AppPaths.createPrivateDirectory(AppPaths.support)
                let output = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                try output.write(to: self.fileURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Saving settings to \(self.fileURL.path) failed: \(error)\n".utf8))
            }
        }
    }

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: self.fileURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    #endif
}
