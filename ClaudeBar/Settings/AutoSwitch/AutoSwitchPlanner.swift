import Foundation

/// Decides which account should carry the live login. Pure functions over UI
/// snapshots, so the policy is testable without keychains or network.
enum AutoSwitchPlanner {
    /// Session headroom, in points below the switch threshold, that makes a
    /// candidate worth preferring. One with less is still usable, but only when
    /// nothing better exists: landing on it means switching again soon.
    static let comfortableHeadroom = 20
    /// A weekly window this full blocks the account outright until it resets.
    static let weeklyExhaustedPercent = 100
    /// After a switch the user made by hand, leave their choice alone this long.
    static let manualSwitchGrace: TimeInterval = 5 * 60
    /// Fastest the active account is re-polled while its usage climbs.
    static let fastestRefresh: TimeInterval = 60
    /// A window whose reset has passed but hasn't been refetched is treated as
    /// freshly opened for ordering purposes.
    static let sessionWindow: TimeInterval = 5 * 60 * 60
    static let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60

    enum Decision: Equatable {
        case stay
        case switchTo(accountId: String, reason: String)
        /// The active account needs relief but no other account can take over.
        case noCandidate(reason: String)
    }

    /// Whether `display` could carry the login right now.
    static func isUsable(_ display: AccountDisplay, threshold: Int, now: Date) -> Bool {
        guard !display.account.needsRelogin, let usage = display.usage else { return false }
        let session = usage.session?.effectiveUsedPercent(at: now) ?? 0
        let weekly = usage.weekly?.effectiveUsedPercent(at: now) ?? 0
        return session < threshold && weekly < Self.weeklyExhaustedPercent
    }

    /// Non-active accounts that could take over, best first: comfortable session
    /// headroom beats little, then the soonest weekly reset (capacity that expires
    /// first is the least valuable to hoard), then the emptier session, then
    /// roster order.
    static func rankedCandidates(_ displays: [AccountDisplay], threshold: Int, now: Date) -> [AccountDisplay] {
        displays
            .filter { !$0.isActive && Self.isUsable($0, threshold: threshold, now: now) }
            .sorted { lhs, rhs in
                let lhsSession = Self.sessionPercent(lhs, now: now)
                let rhsSession = Self.sessionPercent(rhs, now: now)
                let comfortable = threshold - Self.comfortableHeadroom
                if (lhsSession <= comfortable) != (rhsSession <= comfortable) {
                    return lhsSession <= comfortable
                }
                let lhsWeekly = Self.nextReset(of: lhs.usage?.weekly, window: Self.weeklyWindow, now: now)
                let rhsWeekly = Self.nextReset(of: rhs.usage?.weekly, window: Self.weeklyWindow, now: now)
                if lhsWeekly != rhsWeekly { return lhsWeekly < rhsWeekly }
                if lhsSession != rhsSession { return lhsSession < rhsSession }
                // Exact ties fall back to roster order, so the "Next" badge never
                // wanders between two equal accounts from one refresh to the next.
                return lhs.account.displayOrder < rhs.account.displayOrder
            }
    }

    static func decide(
        displays: [AccountDisplay],
        settings: UsageSettings,
        activeRatePercentPerHour: Double?,
        lastManualSwitchAt: Date?,
        now: Date) -> Decision
    {
        guard settings.autoSwitchEnabled,
              let active = displays.first(where: \.isActive),
              let usage = active.usage
        else { return .stay }
        if let lastManualSwitchAt, now.timeIntervalSince(lastManualSwitchAt) < Self.manualSwitchGrace {
            return .stay
        }

        let threshold = settings.switchAtSessionPercent
        let session = usage.session?.effectiveUsedPercent(at: now) ?? 0
        let weekly = usage.weekly?.effectiveUsedPercent(at: now) ?? 0
        let projected = Self.projectedSessionPercent(
            from: session, ratePercentPerHour: activeRatePercentPerHour, over: settings.refreshInterval)

        let reason: String
        if weekly >= Self.weeklyExhaustedPercent {
            reason = "weekly limit used up"
        } else if session >= threshold {
            reason = "session at \(session)%"
        } else if projected >= threshold {
            reason = "session at \(session)% and climbing fast"
        } else {
            return .stay
        }

        guard let best = Self.rankedCandidates(displays, threshold: threshold, now: now).first else {
            return .noCandidate(reason: reason)
        }
        return .switchTo(accountId: best.id, reason: reason)
    }

    /// How long the active account's usage can go unchecked. Without auto-switching
    /// or a measurable climb this is the base interval; otherwise the interval
    /// shrinks so the threshold is seen coming at least two polls ahead.
    static func activeRefreshInterval(
        sessionPercent: Int, ratePercentPerHour: Double?, settings: UsageSettings) -> TimeInterval
    {
        guard settings.autoSwitchEnabled, let rate = ratePercentPerHour, rate > 0 else {
            return settings.refreshInterval
        }
        let remaining = Double(settings.switchAtSessionPercent - sessionPercent)
        guard remaining > 0 else { return Self.fastestRefresh }
        let secondsToThreshold = remaining / rate * 3600
        return min(settings.refreshInterval, max(Self.fastestRefresh, secondsToThreshold / 2))
    }

    static func projectedSessionPercent(
        from current: Int, ratePercentPerHour: Double?, over interval: TimeInterval) -> Int
    {
        guard let rate = ratePercentPerHour, rate > 0 else { return current }
        return current + Int((rate * interval / 3600).rounded())
    }

    private static func sessionPercent(_ display: AccountDisplay, now: Date) -> Int {
        display.usage?.session?.effectiveUsedPercent(at: now) ?? 0
    }

    /// When the window next resets. A reset already behind us means a fresh
    /// window just opened, so the next one is a full window away; no reset time
    /// at all sorts last.
    private static func nextReset(of metric: UsageMetric?, window: TimeInterval, now: Date) -> Date {
        guard let resetsAt = metric?.resetsAt else { return .distantFuture }
        return resetsAt > now ? resetsAt : now.addingTimeInterval(window)
    }
}
