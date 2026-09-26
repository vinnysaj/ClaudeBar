import Foundation

/// When the user tends to be working, as the share of each hour of the week
/// spent actively using up limits.
struct ActivityProfile: Sendable, Equatable {
    static let hoursPerWeek = 7 * 24

    /// Indexed by `hourOfWeek`, so 0 is Sunday 00:00-01:00 local time.
    let hourly: [Double]
    /// Hours of history behind the profile. Where this is thin, the profile is
    /// mostly the configured work schedule.
    let observedHours: Double

    static func hourOfWeek(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.weekday, .hour], from: date)
        return ((components.weekday ?? 1) - 1) * 24 + (components.hour ?? 0)
    }

    static func hourOfWeek(_ weekday: Weekday, hour: Int) -> Int {
        (weekday.rawValue - 1) * 24 + hour
    }

    func share(at date: Date, calendar: Calendar) -> Double {
        self.hourly[Self.hourOfWeek(for: date, calendar: calendar)]
    }

    func share(_ weekday: Weekday, hour: Int) -> Double {
        self.hourly[Self.hourOfWeek(weekday, hour: hour)]
    }

    /// Expected hours of active work across a typical week.
    var weeklyActiveHours: Double { self.hourly.reduce(0, +) }
}

/// How fast an account's limits fill per hour of active work.
struct TypicalPace: Sendable, Equatable {
    let sessionPerActiveHour: Double
    let weeklyPerActiveHour: Double
    /// Hours of active work the pace was measured over.
    let activeHours: Double

    func perActiveHour(_ window: UsageWindow) -> Double {
        switch window {
        case .session: return self.sessionPerActiveHour
        case .weekly: return self.weeklyPerActiveHour
        }
    }
}

/// What the usage history says about the user's rhythm and each account's burn
/// rate. Learned from scratch whenever the history changes; pure, so the whole
/// model is testable from a synthetic history.
struct PaceModel: Sendable {
    /// History is bucketed into slots this long. Coarse enough that a slot with
    /// any work in it shows at least a point of movement, fine enough to follow
    /// a working day. Percentages arrive as whole numbers, so shorter slots would
    /// mistake rounding for idleness.
    static let slotLength: TimeInterval = 15 * 60
    /// An account needs this much measured work before its own pace is trusted
    /// over the pace pooled across every account.
    static let minimumActiveHours: Double = 1
    /// Share of a scheduled working hour assumed active before history says otherwise.
    static let scheduledHourActivity = 0.6
    /// The same for hours outside the schedule.
    static let unscheduledHourActivity = 0.05
    /// How many observed slots the prior counts for. History outweighs it after
    /// a couple of weeks of the same hour.
    static let priorWeight = 8.0

    let activity: ActivityProfile
    let paceByAccount: [String: TypicalPace]
    /// Every account's work together; stands in for accounts without enough of their own.
    let pooledPace: TypicalPace?

    /// The account's own pace when it has enough history, else the pooled one.
    func typicalPace(for accountId: String) -> (pace: TypicalPace, isPooled: Bool)? {
        if let own = self.paceByAccount[accountId], own.activeHours >= Self.minimumActiveHours {
            return (own, false)
        }
        return self.pooledPace.map { ($0, true) }
    }

    static func learn(from history: UsageHistory, schedule: WorkSchedule, calendar: Calendar) -> PaceModel {
        var observedSlots = Set<Int>()
        var activeSlots = Set<Int>()
        var gains: [String: (session: Double, weekly: Double, slots: Set<Int>)] = [:]

        for (accountId, runs) in history.runsByAccount {
            var accountGains = (session: 0.0, weekly: 0.0, slots: Set<Int>())
            for run in runs {
                observedSlots.formUnion(Self.slots(from: run.firstSeen, to: run.lastSeen))
            }
            for (earlier, later) in zip(runs, runs.dropFirst()) {
                guard later.firstSeen.timeIntervalSince(earlier.lastSeen) <= UsageHistory.maximumObservedGap
                else { continue }
                observedSlots.formUnion(Self.slots(from: earlier.lastSeen, to: later.firstSeen))
                let sessionGain = UsageWindow.session.gain(from: earlier.reading, to: later.reading)
                let weeklyGain = UsageWindow.weekly.gain(from: earlier.reading, to: later.reading)
                guard sessionGain > 0 || weeklyGain > 0 else { continue }
                // The movement surfaced at this fetch; the slot it lands in was worked.
                let slot = Self.slot(containing: later.firstSeen)
                activeSlots.insert(slot)
                accountGains.slots.insert(slot)
                accountGains.session += sessionGain
                accountGains.weekly += weeklyGain
            }
            if !accountGains.slots.isEmpty {
                gains[accountId] = accountGains
            }
        }

        let activity = Self.profile(
            observedSlots: observedSlots, activeSlots: activeSlots, schedule: schedule, calendar: calendar)

        let slotHours = Self.slotLength / 3600
        var paceByAccount: [String: TypicalPace] = [:]
        for (accountId, accountGains) in gains {
            let hours = Double(accountGains.slots.count) * slotHours
            paceByAccount[accountId] = TypicalPace(
                sessionPerActiveHour: accountGains.session / hours,
                weeklyPerActiveHour: accountGains.weekly / hours,
                activeHours: hours)
        }
        let pooledHours = paceByAccount.values.reduce(0) { $0 + $1.activeHours }
        let pooledPace: TypicalPace? = pooledHours >= Self.minimumActiveHours
            ? TypicalPace(
                sessionPerActiveHour: gains.values.reduce(0) { $0 + $1.session } / pooledHours,
                weeklyPerActiveHour: gains.values.reduce(0) { $0 + $1.weekly } / pooledHours,
                activeHours: pooledHours)
            : nil

        return PaceModel(activity: activity, paceByAccount: paceByAccount, pooledPace: pooledPace)
    }

    /// Share of each hour of the week that was active, smoothed in two tiers:
    /// each weekday-hour leans on the same hour across all workdays (or all days
    /// off), which in turn leans on the configured schedule. A new install
    /// forecasts from the schedule; a few days in, from what the user actually did.
    private static func profile(
        observedSlots: Set<Int>, activeSlots: Set<Int>,
        schedule: WorkSchedule, calendar: Calendar) -> ActivityProfile
    {
        var observed = [Double](repeating: 0, count: ActivityProfile.hoursPerWeek)
        var active = [Double](repeating: 0, count: ActivityProfile.hoursPerWeek)
        for slot in observedSlots {
            let hour = ActivityProfile.hourOfWeek(for: Self.start(ofSlot: slot), calendar: calendar)
            observed[hour] += 1
            if activeSlots.contains(slot) {
                active[hour] += 1
            }
        }

        func pooled(isWorkday: Bool, hour: Int) -> Double {
            let days = Weekday.allCases.filter { schedule.isWorkday($0) == isWorkday }
            let prior = isWorkday && hour >= schedule.startHour && hour < schedule.endHour
                ? Self.scheduledHourActivity
                : Self.unscheduledHourActivity
            let activeTotal = days.reduce(0) { $0 + active[ActivityProfile.hourOfWeek($1, hour: hour)] }
            let observedTotal = days.reduce(0) { $0 + observed[ActivityProfile.hourOfWeek($1, hour: hour)] }
            return (activeTotal + Self.priorWeight * prior) / (observedTotal + Self.priorWeight)
        }

        var hourly = [Double](repeating: 0, count: ActivityProfile.hoursPerWeek)
        for hour in 0..<24 {
            let workdayShare = pooled(isWorkday: true, hour: hour)
            let dayOffShare = pooled(isWorkday: false, hour: hour)
            for weekday in Weekday.allCases {
                let index = ActivityProfile.hourOfWeek(weekday, hour: hour)
                let prior = schedule.isWorkday(weekday) ? workdayShare : dayOffShare
                hourly[index] = (active[index] + Self.priorWeight * prior) / (observed[index] + Self.priorWeight)
            }
        }
        return ActivityProfile(
            hourly: hourly,
            observedHours: Double(observedSlots.count) * Self.slotLength / 3600)
    }

    private static func slot(containing date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / Self.slotLength).rounded(.down))
    }

    private static func start(ofSlot slot: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(slot) * Self.slotLength)
    }

    private static func slots(from start: Date, to end: Date) -> ClosedRange<Int> {
        Self.slot(containing: start)...Self.slot(containing: max(start, end))
    }
}
