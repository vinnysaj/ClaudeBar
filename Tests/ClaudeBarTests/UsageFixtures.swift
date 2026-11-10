import Foundation
@testable import ClaudeBarCore

/// Deterministic building blocks for the usage tests. Every instant is derived
/// from `UsageFixture.now`, so nothing here depends on the wall clock.
enum UsageFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 60 * 60
    static let day: TimeInterval = 24 * 60 * 60

    /// `now` shifted by `minutes`. Negative values land in the past.
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

    static func account(
        id: String,
        needsRelogin: Bool = false,
        displayOrder: Int = 0,
        allowsAutoSwitch: Bool = true) -> Account
    {
        Account(
            id: id,
            email: "\(id)@example.com",
            organizationName: nil,
            oauthAccountRaw: nil,
            displayOrder: displayOrder,
            needsRelogin: needsRelogin,
            preferences: AccountPreferences(
                sessionLimit: nil, weeklyLimit: nil, fableLimit: nil, allowsAutoSwitch: allowsAutoSwitch))
    }

    /// The limits accounts are held to unless a test gives them their own.
    static let limits = AccountLimits(session: 90, weekly: 95, fable: 95)

    static func usage(
        session: UsageMetric? = nil,
        weekly: UsageMetric? = nil,
        fable: UsageMetric? = nil,
        fetchedAt: Date = UsageFixture.now) -> AccountUsage
    {
        AccountUsage(
            session: session,
            weekly: weekly,
            fable: fable,
            extraUsage: nil,
            fetchedAt: fetchedAt)
    }

    /// An account row with session and weekly windows populated, and a Fable
    /// window when given one. Percentages default to empty windows and reset
    /// times to "no known reset"; a nil session is a verified account's, which has none.
    static func display(
        id: String,
        sessionPercent: Int? = 0,
        sessionResetsAt: Date? = nil,
        weeklyPercent: Int = 0,
        weeklyResetsAt: Date? = nil,
        fablePercent: Int? = nil,
        fableResetsAt: Date? = nil,
        isActive: Bool = false,
        displayOrder: Int = 0,
        needsRelogin: Bool = false,
        allowsAutoSwitch: Bool = true,
        limits: AccountLimits = UsageFixture.limits) -> AccountDisplay
    {
        AccountDisplay(
            account: UsageFixture.account(
                id: id,
                needsRelogin: needsRelogin,
                displayOrder: displayOrder,
                allowsAutoSwitch: allowsAutoSwitch),
            usage: UsageFixture.usage(
                session: sessionPercent.map {
                    UsageFixture.metric(label: "Session", usedPercent: $0, resetsAt: sessionResetsAt)
                },
                weekly: UsageFixture.metric(
                    label: "Week", usedPercent: weeklyPercent, resetsAt: weeklyResetsAt),
                fable: fablePercent.map {
                    UsageFixture.metric(label: "Fable", usedPercent: $0, resetsAt: fableResetsAt)
                }),
            isActive: isActive,
            isRecommended: false,
            isStale: false,
            limits: limits)
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
            isStale: false,
            limits: UsageFixture.limits)
    }

    static func settings(
        refreshInterval: TimeInterval = 5 * 60,
        autoSwitchEnabled: Bool = true) -> UsageSettings
    {
        UsageSettings(
            refreshInterval: refreshInterval,
            autoSwitchEnabled: autoSwitchEnabled,
            switchAtSessionPercent: UsageFixture.limits.session,
            switchAtWeeklyPercent: UsageFixture.limits.weekly,
            switchAtFablePercent: nil,
            workSchedule: .default)
    }
}
