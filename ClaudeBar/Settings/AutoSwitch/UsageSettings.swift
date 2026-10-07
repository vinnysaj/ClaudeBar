import Foundation

/// How often usage is fetched, the limits accounts are held to unless they set
/// their own, and when ClaudeBar moves the live login to another account.
struct UsageSettings: Sendable, Codable, Equatable {
    /// Base interval between usage fetches for each account. While auto-switching,
    /// the active account is polled faster than this as its usage climbs.
    var refreshInterval: TimeInterval
    var autoSwitchEnabled: Bool
    /// Session usage, in percent, at which an account stops taking work.
    var switchAtSessionPercent: Int
    /// Weekly usage, in percent, at which an account stops taking work.
    var switchAtWeeklyPercent: Int
    /// When the user usually works; forecasts lean on it where history is thin.
    var workSchedule: WorkSchedule

    static let `default` = UsageSettings(
        refreshInterval: 5 * 60,
        autoSwitchEnabled: false,
        switchAtSessionPercent: 90,
        switchAtWeeklyPercent: 95,
        workSchedule: .default)

    static let refreshIntervalChoices: [TimeInterval] = [60, 2 * 60, 5 * 60, 10 * 60, 15 * 60]
    static let switchPercentChoices = [70, 75, 80, 85, 90, 95, 98]
    static let weeklyPercentChoices = [70, 75, 80, 85, 90, 95, 98, 100]

    /// The limits an account is held to: its own where it sets them, these defaults otherwise.
    func limits(for preferences: AccountPreferences) -> AccountLimits {
        AccountLimits(
            session: preferences.sessionLimit ?? self.switchAtSessionPercent,
            weekly: preferences.weeklyLimit ?? self.switchAtWeeklyPercent)
    }

    private static let defaultsKey = "usageSettings"

    static var saved: UsageSettings {
        get { Preferences.read(UsageSettings.self, key: Self.defaultsKey) ?? .default }
        set { Preferences.write(newValue, key: Self.defaultsKey) }
    }
}

extension UsageSettings {
    /// Fields added after the first release fall back to their defaults, so a saved
    /// preference from an older build keeps the choices it does record.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = UsageSettings.default
        self.refreshInterval = try container.decode(TimeInterval.self, forKey: .refreshInterval)
        self.autoSwitchEnabled = try container.decode(Bool.self, forKey: .autoSwitchEnabled)
        self.switchAtSessionPercent = try container.decode(Int.self, forKey: .switchAtSessionPercent)
        self.switchAtWeeklyPercent = try container.decodeIfPresent(Int.self, forKey: .switchAtWeeklyPercent)
            ?? fallback.switchAtWeeklyPercent
        self.workSchedule = try container.decodeIfPresent(WorkSchedule.self, forKey: .workSchedule)
            ?? fallback.workSchedule
    }
}
