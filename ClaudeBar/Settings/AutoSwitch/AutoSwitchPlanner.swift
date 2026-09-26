import Foundation

/// Decides which account should carry the live login. Pure functions over
/// snapshots, so the policy is testable without keychains or network, and the
/// forecaster can replay it against simulated usage.
enum AutoSwitchPlanner {
    /// Session room, in points below its limit, a candidate needs to be worth
    /// moving to at all; with less it would hand the login on within minutes.
    static let minimumSessionRoom: Double = 5
    /// Weekly room a candidate needs. A weekly point buys far more work than a
    /// session point, so a smaller margin is still worth using.
    static let minimumWeeklyRoom: Double = 3
    /// Session room that makes a candidate preferred. One with less is still
    /// usable, but only when nothing better exists: every switch starts running
    /// sessions over on a cold prompt cache, so landing somewhere that fills up
    /// soon costs usage as well as a second switch.
    static let comfortableSessionRoom: Double = 20
    /// After a switch the user made by hand, leave their choice alone this long.
    static let manualSwitchGrace: TimeInterval = 5 * 60
    /// Fastest the active account is re-polled while its usage climbs.
    static let fastestRefresh: TimeInterval = 60
    /// How often the app checks whether any account is due a refresh, so how
    /// long past its interval a due refresh can wait.
    static let pollingTick: TimeInterval = 60
    /// A candidate's cached usage older than this is refetched before the login
    /// moves to it: claude.ai or another machine may have used it since.
    static let candidateFreshness: TimeInterval = 2 * 60
    static let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60

    /// The planner's view of one account at one moment.
    struct Candidate: Sendable, Equatable {
        let id: String
        let sessionPercent: Double
        let weeklyPercent: Double
        /// When the weekly window next resets; nil when unknown.
        let weeklyResetsAt: Date?
        let limits: AccountLimits
        /// Signed in, with usage known, and open to auto-switching.
        let isAvailable: Bool
        let displayOrder: Int

        func room(_ window: UsageWindow) -> Double {
            switch window {
            case .session: return Double(self.limits.session) - self.sessionPercent
            case .weekly: return Double(self.limits.weekly) - self.weeklyPercent
            }
        }
    }

    enum Decision: Equatable {
        case stay
        case switchTo(accountId: String, reason: SwitchReason)
        /// The active account needs relief but no other account can take over.
        case noCandidate(reason: SwitchReason)
    }

    /// Whether `candidate` could take the login over right now with enough room
    /// under both of its limits to be worth the move.
    static func canTakeOver(_ candidate: Candidate) -> Bool {
        candidate.isAvailable
            && candidate.room(.session) >= Self.minimumSessionRoom
            && candidate.room(.weekly) >= Self.minimumWeeklyRoom
    }

    /// Accounts that could take over, best first: comfortable session room beats
    /// little, then the soonest weekly reset (capacity that expires first is the
    /// least valuable to hoard), then the roomier session, then roster order.
    static func rank(_ candidates: [Candidate]) -> [Candidate] {
        candidates
            .filter(Self.canTakeOver)
            .sorted { lhs, rhs in
                let lhsComfortable = lhs.room(.session) >= Self.comfortableSessionRoom
                let rhsComfortable = rhs.room(.session) >= Self.comfortableSessionRoom
                if lhsComfortable != rhsComfortable { return lhsComfortable }
                let lhsReset = lhs.weeklyResetsAt ?? .distantFuture
                let rhsReset = rhs.weeklyResetsAt ?? .distantFuture
                if lhsReset != rhsReset { return lhsReset < rhsReset }
                if lhs.room(.session) != rhs.room(.session) { return lhs.room(.session) > rhs.room(.session) }
                // Exact ties fall back to roster order, so the "Next" badge never
                // wanders between two equal accounts from one refresh to the next.
                return lhs.displayOrder < rhs.displayOrder
            }
    }

    /// Non-active accounts that could take over, best first.
    static func rankedCandidates(_ displays: [AccountDisplay], now: Date) -> [AccountDisplay] {
        let displaysById = Dictionary(displays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self.rank(displays.filter { !$0.isActive }.map { Candidate(display: $0, now: now) })
            .compactMap { displaysById[$0.id] }
    }

    /// Why the active account should hand the login over now, or nil while it
    /// has room. It hands over at either limit, or before one when its usage is
    /// climbing fast enough to cross it within `lookahead`.
    static func reliefReason(for active: Candidate, pace: CurrentPace?, lookahead: TimeInterval) -> SwitchReason? {
        let session = Int(active.sessionPercent.rounded())
        let weekly = Int(active.weeklyPercent.rounded())
        if active.room(.weekly) <= 0 {
            return .weeklyAtLimit(percent: weekly, limit: active.limits.weekly)
        }
        if active.room(.session) <= 0 {
            return .sessionAtLimit(percent: session, limit: active.limits.session)
        }
        if Self.growth(pace?.sessionPerHour, over: lookahead) >= active.room(.session) {
            return .sessionClimbing(percent: session, limit: active.limits.session)
        }
        if Self.growth(pace?.weeklyPerHour, over: lookahead) >= active.room(.weekly) {
            return .weeklyClimbing(percent: weekly, limit: active.limits.weekly)
        }
        return nil
    }

    static func decide(
        displays: [AccountDisplay],
        settings: UsageSettings,
        activePace: CurrentPace?,
        lastManualSwitchAt: Date?,
        now: Date) -> Decision
    {
        guard settings.autoSwitchEnabled,
              let activeDisplay = displays.first(where: \.isActive),
              activeDisplay.usage != nil
        else { return .stay }
        if let lastManualSwitchAt, now.timeIntervalSince(lastManualSwitchAt) < Self.manualSwitchGrace {
            return .stay
        }

        let active = Candidate(display: activeDisplay, now: now)
        // A switch only happens at a check, so anything that would cross a limit
        // before the check after this one has to move now.
        let lookahead = Self.activeRefreshInterval(active: active, pace: activePace, settings: settings)
            + Self.pollingTick
        guard let reason = Self.reliefReason(for: active, pace: activePace, lookahead: lookahead) else {
            return .stay
        }
        guard let best = Self.rankedCandidates(displays, now: now).first else {
            return .noCandidate(reason: reason)
        }
        return .switchTo(accountId: best.id, reason: reason)
    }

    /// How long the active account's usage can go unchecked. Without
    /// auto-switching or a measurable climb this is the base interval; otherwise
    /// it shrinks so the nearer limit is seen coming at least two polls ahead.
    static func activeRefreshInterval(active: Candidate?, pace: CurrentPace?, settings: UsageSettings) -> TimeInterval {
        guard settings.autoSwitchEnabled, let active else { return settings.refreshInterval }
        let secondsToLimit = UsageWindow.allCases
            .compactMap { window -> TimeInterval? in
                guard let rate = pace?.perHour(window), rate > 0 else { return nil }
                return max(0, active.room(window)) / rate * 3600
            }
            .min()
        guard let secondsToLimit else { return settings.refreshInterval }
        guard secondsToLimit > 0 else { return Self.fastestRefresh }
        return min(settings.refreshInterval, max(Self.fastestRefresh, secondsToLimit / 2))
    }

    /// Points a window gains over `interval` at `ratePerHour`; nothing for a flat or falling rate.
    static func growth(_ ratePerHour: Double?, over interval: TimeInterval) -> Double {
        guard let ratePerHour, ratePerHour > 0 else { return 0 }
        return ratePerHour * interval / 3600
    }

    /// When a window next resets. A reset already behind us means a fresh
    /// window just opened, so the next one is a full window away.
    static func nextReset(_ resetsAt: Date?, window: TimeInterval, now: Date) -> Date? {
        guard let resetsAt else { return nil }
        return resetsAt > now ? resetsAt : now.addingTimeInterval(window)
    }
}

extension AutoSwitchPlanner.Candidate {
    init(display: AccountDisplay, now: Date) {
        self.init(
            id: display.id,
            sessionPercent: Double(display.usage?.session?.effectiveUsedPercent(at: now) ?? 0),
            weeklyPercent: Double(display.usage?.weekly?.effectiveUsedPercent(at: now) ?? 0),
            weeklyResetsAt: AutoSwitchPlanner.nextReset(
                display.usage?.weekly?.resetsAt, window: AutoSwitchPlanner.weeklyWindow, now: now),
            limits: display.limits,
            isAvailable: !display.account.needsRelogin
                && display.usage != nil
                && display.account.preferences.allowsAutoSwitch,
            displayOrder: display.account.displayOrder)
    }
}
