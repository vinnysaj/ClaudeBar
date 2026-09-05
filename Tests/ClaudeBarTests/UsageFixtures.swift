import Foundation
@testable import ClaudeBar

/// Deterministic building blocks for the usage tests. Every instant is derived
/// from `UsageFixture.now`, so nothing here depends on the wall clock.
enum UsageFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 60 * 60
    static let day: TimeInterval = 24 * 60 * 60

    /// `now` shifted by `seconds`. Negative values land in the past.
    static func secondsFromNow(_ seconds: TimeInterval) -> Date {
        UsageFixture.now.addingTimeInterval(seconds)
    }

    static func minutesFromNow(_ minutes: Double) -> Date {
        UsageFixture.now.addingTimeInterval(minutes * UsageFixture.minute)
    }

    static func hoursFromNow(_ hours: Double) -> Date {
        UsageFixture.now.addingTimeInterval(hours * UsageFixture.hour)
    }

    static func daysFromNow(_ days: Double) -> Date {
        UsageFixture.now.addingTimeInterval(days * UsageFixture.day)
    }

    static func metric(label: String, usedPercent: Int, resetsAt: Date?) -> UsageMetric {
        UsageMetric(
            label: label,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            spentDescription: nil,
            isUnlimited: false)
    }

    static func account(id: String, needsRelogin: Bool = false, displayOrder: Int = 0) -> Account {
        Account(
            id: id,
            email: "\(id)@example.com",
            organizationName: nil,
            oauthAccountRaw: nil,
            displayOrder: displayOrder,
            needsRelogin: needsRelogin)
    }

    static func usage(
        session: UsageMetric? = nil,
        weekly: UsageMetric? = nil,
        fable: UsageMetric? = nil,
        extraUsage: UsageMetric? = nil,
        fetchedAt: Date = UsageFixture.now) -> AccountUsage
    {
        AccountUsage(
            session: session,
            weekly: weekly,
            fable: fable,
            extraUsage: extraUsage,
            fetchedAt: fetchedAt)
    }

    /// An account row with both limit windows populated. Percentages default to
    /// empty windows and reset times to "no known reset".
    static func display(
        id: String,
        sessionPercent: Int = 0,
        sessionResetsAt: Date? = nil,
        weeklyPercent: Int = 0,
        weeklyResetsAt: Date? = nil,
        isActive: Bool = false,
        displayOrder: Int = 0,
        needsRelogin: Bool = false,
        fetchedAt: Date = UsageFixture.now) -> AccountDisplay
    {
        AccountDisplay(
            account: UsageFixture.account(
                id: id, needsRelogin: needsRelogin, displayOrder: displayOrder),
            usage: UsageFixture.usage(
                session: UsageFixture.metric(
                    label: "Session", usedPercent: sessionPercent, resetsAt: sessionResetsAt),
                weekly: UsageFixture.metric(
                    label: "Week", usedPercent: weeklyPercent, resetsAt: weeklyResetsAt),
                fetchedAt: fetchedAt),
            isActive: isActive,
            isRecommended: false,
            isStale: false)
    }

    /// An account whose usage has never been fetched.
    static func displayWithoutUsage(
        id: String,
        isActive: Bool = false,
        needsRelogin: Bool = false) -> AccountDisplay
    {
        AccountDisplay(
            account: UsageFixture.account(id: id, needsRelogin: needsRelogin),
            usage: nil,
            isActive: isActive,
            isRecommended: false,
            isStale: false)
    }

    static func settings(
        refreshInterval: TimeInterval = 5 * 60,
        autoSwitchEnabled: Bool = true,
        switchAtSessionPercent: Int = 90) -> UsageSettings
    {
        UsageSettings(
            refreshInterval: refreshInterval,
            autoSwitchEnabled: autoSwitchEnabled,
            switchAtSessionPercent: switchAtSessionPercent)
    }
}
