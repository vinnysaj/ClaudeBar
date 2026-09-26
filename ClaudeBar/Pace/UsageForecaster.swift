import Foundation

/// Expected work over time: the learned weekly rhythm, bent toward what the
/// user is doing right now for the next few hours.
struct DemandCurve: Sendable {
    /// How quickly the present fades into the usual rhythm: after this long the
    /// current burst or lull still counts for about a third.
    static let momentumDecay: TimeInterval = 2 * 60 * 60

    let activity: ActivityProfile
    let calendar: Calendar
    let now: Date
    /// Work intensity right now relative to the typical pace: 0 idle, 1 typical,
    /// 2 twice as hard. Nil when there's nothing recent to go on.
    let currentIntensity: Double?

    /// Expected hours of typical-pace work per hour at `date`.
    func intensity(at date: Date) -> Double {
        let usual = self.activity.share(at: date, calendar: self.calendar)
        guard let current = self.currentIntensity else { return usual }
        let weight = exp(-max(0, date.timeIntervalSince(self.now)) / Self.momentumDecay)
        return usual + (current - usual) * weight
    }
}

/// What the usage of one account looks like ahead if all work went to it.
struct AccountForecast: Sendable, Equatable {
    /// When the open session would reach its limit, if before it resets.
    let sessionLimitAt: Date?
    /// Session usage expected when the open session resets, when it doesn't
    /// reach its limit first.
    let sessionPercentAtReset: Double?
    /// When weekly usage would reach its limit, if before the weekly reset.
    let weeklyLimitAt: Date?
    /// Weekly usage expected at the weekly reset, when it doesn't reach its
    /// limit first.
    let weeklyPercentAtReset: Double?
    /// Expected weekly usage from now until the reset (or the horizon).
    let weeklyProjection: [UsagePoint]
}

/// Whether the accounts together can carry the expected work.
struct FleetForecast: Sendable, Equatable {
    /// When every usable account would be at its limits while work is still
    /// expected; nil when capacity holds for the whole horizon.
    let runsOutAt: Date?
    /// When capacity comes back after `runsOutAt`; nil if not within the horizon.
    let resumesAt: Date?
    /// Hours of expected work within the horizon that no account could take.
    let shortfallHours: Double
    /// Hours of work expected within the horizon.
    let expectedWorkHours: Double
    /// Hours of work the usable accounts' remaining weekly room covers at the
    /// typical pace, before any reset tops it up.
    let bankedHours: Double
    let horizonEnd: Date

    var isCovered: Bool { self.runsOutAt == nil }
}

/// Replays expected work against the accounts' limits, resets and the
/// auto-switch policy, a quarter hour at a time.
enum UsageForecaster {
    static let step: TimeInterval = 15 * 60
    static let horizon: TimeInterval = 7 * 24 * 60 * 60
    static let sessionWindow: TimeInterval = 5 * 60 * 60
    /// Running short by less than this is a rounding artifact, not running out.
    static let negligibleShortfallHours = 0.25
    /// Room this close to zero counts as full; floating-point sums rarely land exactly.
    private static let epsilon = 1e-6

    /// One account's state as the simulation advances.
    struct Account: Sendable, Equatable {
        let id: String
        var sessionPercent: Double
        /// When the open session window resets; nil when none is open.
        var sessionResetsAt: Date?
        var weeklyPercent: Double
        var weeklyResetsAt: Date?
        let limits: AccountLimits
        let pace: TypicalPace
        /// Signed in and open to auto-switching.
        let isAvailable: Bool
        let displayOrder: Int

        fileprivate var canWork: Bool {
            Double(self.limits.session) - self.sessionPercent > UsageForecaster.epsilon
                && Double(self.limits.weekly) - self.weeklyPercent > UsageForecaster.epsilon
        }

        fileprivate var candidate: AutoSwitchPlanner.Candidate {
            AutoSwitchPlanner.Candidate(
                id: self.id,
                sessionPercent: self.sessionPercent,
                weeklyPercent: self.weeklyPercent,
                weeklyResetsAt: self.weeklyResetsAt,
                limits: self.limits,
                isAvailable: self.isAvailable,
                displayOrder: self.displayOrder)
        }

        /// Hours of work this account covers before its remaining weekly room runs
        /// out at its typical pace; nil when the pace shows no weekly movement.
        var bankedHours: Double? {
            guard self.pace.weeklyPerActiveHour > 0 else { return nil }
            return max(0, Double(self.limits.weekly) - self.weeklyPercent) / self.pace.weeklyPerActiveHour
        }

        /// Takes up to `hours` of work, stopping at either limit. Returns the hours taken.
        fileprivate mutating func take(_ hours: Double, at time: Date) -> Double {
            if self.sessionResetsAt == nil {
                self.sessionResetsAt = time.addingTimeInterval(UsageForecaster.sessionWindow)
            }
            var taken = hours
            if self.pace.sessionPerActiveHour > 0 {
                let room = max(0, Double(self.limits.session) - self.sessionPercent)
                taken = min(taken, room / self.pace.sessionPerActiveHour)
            }
            if self.pace.weeklyPerActiveHour > 0 {
                let room = max(0, Double(self.limits.weekly) - self.weeklyPercent)
                taken = min(taken, room / self.pace.weeklyPerActiveHour)
            }
            self.sessionPercent += taken * self.pace.sessionPerActiveHour
            self.weeklyPercent += taken * self.pace.weeklyPerActiveHour
            return taken
        }
    }

    private struct Simulation {
        var accounts: [Account]
        var activeIndex: Int?
        /// Whether work may move off the active account when it fills up.
        let switchesAccounts: Bool

        mutating func applyResets(at time: Date) {
            for index in self.accounts.indices {
                if let resetsAt = self.accounts[index].sessionResetsAt, resetsAt <= time {
                    self.accounts[index].sessionPercent = 0
                    self.accounts[index].sessionResetsAt = nil
                }
                while let resetsAt = self.accounts[index].weeklyResetsAt, resetsAt <= time {
                    self.accounts[index].weeklyPercent = 0
                    self.accounts[index].weeklyResetsAt = resetsAt.addingTimeInterval(AutoSwitchPlanner.weeklyWindow)
                }
            }
        }

        /// The next quarter-hour boundary or reset, whichever comes first, so a
        /// reset always lands on a step edge.
        func nextBoundary(after time: Date) -> Date {
            let slot = (time.timeIntervalSinceReferenceDate / UsageForecaster.step).rounded(.down) + 1
            var boundary = Date(timeIntervalSinceReferenceDate: slot * UsageForecaster.step)
            for account in self.accounts {
                for resetsAt in [account.sessionResetsAt, account.weeklyResetsAt].compactMap({ $0 })
                where resetsAt > time && resetsAt < boundary {
                    boundary = resetsAt
                }
            }
            return boundary
        }

        /// Hands `hours` of work to accounts in turn, as auto-switching would.
        /// Returns the hours no account could take.
        mutating func serve(_ hours: Double, at time: Date) -> Double {
            var remaining = hours
            // Each pass either finishes the work or fills an account, so this ends.
            while remaining > UsageForecaster.epsilon {
                guard let index = self.accountForWork() else { return remaining }
                self.activeIndex = index
                remaining -= self.accounts[index].take(remaining, at: time)
            }
            return 0
        }

        private func accountForWork() -> Int? {
            if let activeIndex, self.accounts[activeIndex].canWork { return activeIndex }
            guard self.switchesAccounts else { return nil }
            let candidates = self.accounts.indices
                .filter { $0 != self.activeIndex }
                .map { self.accounts[$0].candidate }
            guard let best = AutoSwitchPlanner.rank(candidates).first else { return nil }
            return self.accounts.firstIndex { $0.id == best.id }
        }
    }

    /// Whether the accounts together carry the expected work over the horizon,
    /// switching between them the way auto-switching does.
    static func fleet(accounts: [Account], activeId: String?, demand: DemandCurve) -> FleetForecast {
        let activeIndex = accounts.firstIndex { $0.id == activeId }
        var simulation = Simulation(accounts: accounts, activeIndex: activeIndex, switchesAccounts: true)
        let end = demand.now.addingTimeInterval(Self.horizon)

        var time = demand.now
        var expectedWork = 0.0
        var totalShortfall = 0.0
        // An episode runs from the first step left short until a step with work
        // in it is fully served again.
        var episode: (start: Date, shortfall: Double)?
        var runsOut: (at: Date, resumesAt: Date?)?

        while time < end {
            let next = min(simulation.nextBoundary(after: time), end)
            simulation.applyResets(at: time)
            let work = demand.intensity(at: time) * next.timeIntervalSince(time) / 3600
            expectedWork += work
            let unserved = simulation.serve(work, at: time)
            totalShortfall += unserved

            if unserved > Self.epsilon {
                let start = episode?.start ?? time
                episode = (start, (episode?.shortfall ?? 0) + unserved)
            } else if work > Self.epsilon, let finished = episode {
                if runsOut == nil, finished.shortfall >= Self.negligibleShortfallHours {
                    runsOut = (finished.start, time)
                }
                episode = nil
            }
            time = next
        }
        if runsOut == nil, let unfinished = episode, unfinished.shortfall >= Self.negligibleShortfallHours {
            runsOut = (unfinished.start, nil)
        }

        let banked = accounts
            .filter { $0.isAvailable || $0.id == activeId }
            .compactMap(\.bankedHours)
            .reduce(0, +)
        return FleetForecast(
            runsOutAt: runsOut?.at,
            resumesAt: runsOut?.resumesAt,
            shortfallHours: totalShortfall,
            expectedWorkHours: expectedWork,
            bankedHours: banked,
            horizonEnd: end)
    }

    /// How one account's usage unfolds if every hour of expected work goes to it
    /// until its weekly window resets.
    static func account(_ account: Account, demand: DemandCurve) -> AccountForecast {
        var simulation = Simulation(accounts: [account], activeIndex: 0, switchesAccounts: false)
        let start = demand.now
        let openSessionResetsAt = account.sessionResetsAt.flatMap { $0 > start ? $0 : nil }
        let weeklyResetsAt = account.weeklyResetsAt.flatMap { $0 > start ? $0 : nil }
        let end = min(weeklyResetsAt ?? start.addingTimeInterval(Self.horizon), start.addingTimeInterval(Self.horizon))

        var time = start
        var sessionLimitAt: Date?
        var sessionPercentAtReset: Double?
        var weeklyLimitAt: Date?
        var projection = [UsagePoint(time: start, percent: account.weeklyPercent)]

        while time < end {
            let next = min(simulation.nextBoundary(after: time), end)
            if let openSessionResetsAt, time >= openSessionResetsAt,
               sessionLimitAt == nil, sessionPercentAtReset == nil
            {
                sessionPercentAtReset = simulation.accounts[0].sessionPercent
            }
            simulation.applyResets(at: time)

            let before = simulation.accounts[0]
            let work = demand.intensity(at: time) * next.timeIntervalSince(time) / 3600
            let taken = work - simulation.serve(work, at: time)
            let after = simulation.accounts[0]
            // Where in the step the account filled up, assuming work arrives evenly.
            let filledAt = time.addingTimeInterval(work > 0 ? next.timeIntervalSince(time) * taken / work : 0)

            if let openSessionResetsAt, time < openSessionResetsAt, sessionLimitAt == nil,
               before.canWork, Double(after.limits.session) - after.sessionPercent <= Self.epsilon
            {
                sessionLimitAt = filledAt
            }
            if weeklyLimitAt == nil, Double(after.limits.weekly) - after.weeklyPercent <= Self.epsilon {
                weeklyLimitAt = filledAt
                projection.append(UsagePoint(time: filledAt, percent: after.weeklyPercent))
            }
            let isOnTheHour = next.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) == 0
            if isOnTheHour || next == end {
                projection.append(UsagePoint(time: next, percent: after.weeklyPercent))
            }
            time = next
        }
        if let openSessionResetsAt, openSessionResetsAt <= end,
           sessionLimitAt == nil, sessionPercentAtReset == nil
        {
            sessionPercentAtReset = simulation.accounts[0].sessionPercent
        }

        return AccountForecast(
            sessionLimitAt: sessionLimitAt,
            sessionPercentAtReset: sessionPercentAtReset,
            weeklyLimitAt: weeklyLimitAt,
            weeklyPercentAtReset: weeklyLimitAt == nil && weeklyResetsAt != nil
                ? simulation.accounts[0].weeklyPercent
                : nil,
            weeklyProjection: projection)
    }
}
