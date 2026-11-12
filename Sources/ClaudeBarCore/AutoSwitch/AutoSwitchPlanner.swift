import Foundation

/// Decides which account should carry the live login. Pure functions over
/// snapshots, so the policy is testable without keychains or network, and the
/// forecaster can replay it against simulated usage.
///
/// `fableInUse` says whether Claude Code on this machine is running Fable work.
/// The Fable limit stops only Fable work, so without any here it is no reason
/// to move the login and Fable room no reason to prefer an account. Another
/// machine signed into the same accounts moves their Fable usage all the same,
/// which is why usage alone can't decide it.
public enum AutoSwitchPlanner {
    /// Session room, in points below its limit, a candidate needs to be worth
    /// moving to at all; with less it would hand the login on within minutes.
    public static let minimumSessionRoom: Double = 5
    /// Weekly room a candidate needs. A weekly point buys far more work than a
    /// session point, so a smaller margin is still worth using. Fable is a weekly
    /// window too, and Fable work moves only onto an account with this much Fable room.
    public static let minimumWeeklyRoom: Double = 3
    /// Session room that makes a candidate preferred. One with less is still
    /// usable, but only when nothing better exists: every switch starts running
    /// sessions over on a cold prompt cache, so landing somewhere that fills up
    /// soon costs usage as well as a second switch.
    public static let comfortableSessionRoom: Double = 20
    /// After a switch the user made by hand, leave their choice alone this long.
    public static let manualSwitchGrace: TimeInterval = 5 * 60
    /// Fastest the active account is re-polled while its usage climbs.
    public static let fastestRefresh: TimeInterval = 60
    /// How often the app checks whether any account is due a refresh, so how
    /// long past its interval a due refresh can wait.
    public static let pollingTick: TimeInterval = 60
    /// A candidate's cached usage older than this is refetched before the login
    /// moves to it: claude.ai or another machine may have used it since.
    public static let candidateFreshness: TimeInterval = 2 * 60
    public static let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60

    /// The planner's view of one account at one moment. A window the account
    /// doesn't report reads as empty: verified accounts have no session limit.
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let sessionPercent: Double
        public let weeklyPercent: Double
        public let fablePercent: Double
        /// When the weekly window next resets; nil when unknown.
        public let weeklyResetsAt: Date?
        public let limits: AccountLimits
        /// Signed in, with usage known, and open to auto-switching.
        public let isAvailable: Bool
        public let displayOrder: Int

        public func room(_ window: UsageWindow) -> Double {
            switch window {
            case .session: return Double(self.limits.session) - self.sessionPercent
            case .weekly: return Double(self.limits.weekly) - self.weeklyPercent
            case .fable: return Double(self.limits.fable) - self.fablePercent
            }
        }

        /// Room enough under its Fable limit to take Fable work over.
        public var hasFableRoom: Bool {
            self.room(.fable) >= AutoSwitchPlanner.minimumWeeklyRoom
        }
    }

    public enum Decision: Sendable, Equatable {
        case stay
        case switchTo(accountId: String, reason: SwitchReason)
        /// The active account needs relief but no other account can take over.
        case noCandidate(reason: SwitchReason)
    }

    /// Whether `candidate` could take the login over right now with enough room
    /// under its session and weekly limits to be worth the move. Fable room only
    /// decides where Fable work goes: work in other models carries on without it.
    public static func canTakeOver(_ candidate: Candidate) -> Bool {
        candidate.isAvailable
            && candidate.room(.session) >= Self.minimumSessionRoom
            && candidate.room(.weekly) >= Self.minimumWeeklyRoom
    }

    /// Accounts that could take over, best first: while Fable is in use, Fable
    /// room beats none, so a long Fable run moves from one account's Fable to
    /// the next; then comfortable session room beats little, then the soonest
    /// weekly reset (capacity that expires first is the least valuable to
    /// hoard), then the roomier session, then roster order.
    public static func rank(_ candidates: [Candidate], fableInUse: Bool) -> [Candidate] {
        candidates
            .filter(Self.canTakeOver)
            .sorted { lhs, rhs in
                if fableInUse, lhs.hasFableRoom != rhs.hasFableRoom { return lhs.hasFableRoom }
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
    public static func rankedCandidates(_ displays: [AccountDisplay], fableInUse: Bool, now: Date) -> [AccountDisplay] {
        let displaysById = Dictionary(displays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self.rank(
            displays.filter { !$0.isActive }.map { Candidate(display: $0, now: now) }, fableInUse: fableInUse)
            .compactMap { displaysById[$0.id] }
    }

    /// Why the active account should hand the login over now, or nil while it
    /// has room. It hands over at any limit, or before one when its usage is
    /// climbing fast enough to cross it within `lookahead`. Session and weekly
    /// come first: they stop all work, where the Fable limit stops only Fable,
    /// and counts only while Fable is in use.
    public static func reliefReason(
        for active: Candidate, pace: CurrentPace?, fableInUse: Bool, lookahead: TimeInterval) -> SwitchReason?
    {
        let session = Int(active.sessionPercent.rounded())
        let weekly = Int(active.weeklyPercent.rounded())
        let fable = Int(active.fablePercent.rounded())
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
        guard fableInUse else { return nil }
        if active.room(.fable) <= 0 {
            return .fableAtLimit(percent: fable, limit: active.limits.fable)
        }
        if Self.growth(pace?.fablePerHour, over: lookahead) >= active.room(.fable) {
            return .fableClimbing(percent: fable, limit: active.limits.fable)
        }
        return nil
    }

    public static func decide(
        displays: [AccountDisplay],
        settings: UsageSettings,
        activePace: CurrentPace?,
        fableInUse: Bool,
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
        let lookahead = Self.activeRefreshInterval(
            active: active, pace: activePace, fableInUse: fableInUse, settings: settings)
            + Self.pollingTick
        guard let reason = Self.reliefReason(
            for: active, pace: activePace, fableInUse: fableInUse, lookahead: lookahead)
        else { return .stay }
        // Fable room ranks first, so if the best has none, no account has any,
        // and moving for Fable's sake would gain nothing.
        guard let best = Self.rankedCandidates(displays, fableInUse: fableInUse, now: now).first,
              reason.window != .fable || Candidate(display: best, now: now).hasFableRoom
        else {
            return .noCandidate(reason: reason)
        }
        return .switchTo(accountId: best.id, reason: reason)
    }

    /// How long the active account's usage can go unchecked. Without
    /// auto-switching or a measurable climb this is the base interval; otherwise
    /// it shrinks so the nearest limit, Fable's while Fable is in use, is seen
    /// coming at least two polls ahead.
    public static func activeRefreshInterval(
        active: Candidate?, pace: CurrentPace?, fableInUse: Bool, settings: UsageSettings) -> TimeInterval
    {
        guard settings.autoSwitchEnabled, let active else { return settings.refreshInterval }
        let secondsToLimit = UsageWindow.allCases
            .filter { fableInUse || $0 != .fable }
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
    public static func growth(_ ratePerHour: Double?, over interval: TimeInterval) -> Double {
        guard let ratePerHour, ratePerHour > 0 else { return 0 }
        return ratePerHour * interval / 3600
    }

    /// When a window next resets. A reset already behind us means a fresh
    /// window just opened, so the next one is a full window away.
    public static func nextReset(_ resetsAt: Date?, window: TimeInterval, now: Date) -> Date? {
        guard let resetsAt else { return nil }
        return resetsAt > now ? resetsAt : now.addingTimeInterval(window)
    }
}

extension AutoSwitchPlanner.Candidate {
    public init(display: AccountDisplay, now: Date) {
        self.init(
            id: display.id,
            sessionPercent: Double(display.usage?.session?.effectiveUsedPercent(at: now) ?? 0),
            weeklyPercent: Double(display.usage?.weekly?.effectiveUsedPercent(at: now) ?? 0),
            fablePercent: Double(display.usage?.fable?.effectiveUsedPercent(at: now) ?? 0),
            weeklyResetsAt: AutoSwitchPlanner.nextReset(
                display.usage?.weekly?.resetsAt, window: AutoSwitchPlanner.weeklyWindow, now: now),
            limits: display.limits,
            isAvailable: !display.account.needsRelogin
                && display.usage != nil
                && display.account.preferences.allowsAutoSwitch,
            displayOrder: display.account.displayOrder)
    }
}
