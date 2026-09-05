import Foundation

/// How often usage is fetched, and when ClaudeBar moves the live login to
/// another account on its own.
struct UsageSettings: Sendable, Codable, Equatable {
    /// Base interval between usage fetches for each account. While auto-switching,
    /// the active account is polled faster than this as its usage climbs.
    var refreshInterval: TimeInterval
    var autoSwitchEnabled: Bool
    /// Session usage, in percent, at which the active account is abandoned.
    var switchAtSessionPercent: Int

    static let `default` = UsageSettings(
        refreshInterval: 5 * 60,
        autoSwitchEnabled: false,
        switchAtSessionPercent: 90)

    static let refreshIntervalChoices: [TimeInterval] = [60, 2 * 60, 5 * 60, 10 * 60, 15 * 60]
    static let switchPercentChoices = [70, 75, 80, 85, 90, 95]

    private static let defaultsKey = "usageSettings"

    static var saved: UsageSettings {
        get { Preferences.read(UsageSettings.self, key: Self.defaultsKey) ?? .default }
        set { Preferences.write(newValue, key: Self.defaultsKey) }
    }
}
