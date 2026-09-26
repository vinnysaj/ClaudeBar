import Foundation
import Testing
@testable import ClaudeBar

private let now = UsageFixture.now

/// Ids of the accounts that could take the login over, best first.
private func rankedIds(_ displays: [AccountDisplay]) -> [String] {
    AutoSwitchPlanner.rankedCandidates(displays, now: now).map(\.id)
}

@Suite("Taking over")
struct AutoSwitchTakeOverTests {
    @Test("Accounts signed out, never fetched, or closed to auto-switching cannot take over")
    func unavailableAccountsAreExcluded() {
        let displays = [
            UsageFixture.display(id: "loggedOut", needsRelogin: true),
            UsageFixture.displayWithoutUsage(id: "neverFetched"),
            UsageFixture.display(id: "optedOut", allowsAutoSwitch: false),
            UsageFixture.display(id: "spare", sessionPercent: 30),
        ]
        #expect(rankedIds(displays) == ["spare"])
    }

    @Test(
        "An account needs five session and three weekly points of room under its own limits to take over",
        arguments: [
            // Five points under a seventy session limit is enough; four is not.
            (sessionPercent: 65, weeklyPercent: 0, canTakeOver: true),
            (sessionPercent: 66, weeklyPercent: 0, canTakeOver: false),
            // Three points under an eighty weekly limit is enough; two is not.
            (sessionPercent: 0, weeklyPercent: 77, canTakeOver: true),
            (sessionPercent: 0, weeklyPercent: 78, canTakeOver: false),
        ])
    func minimumRoomUnderOwnLimits(sessionPercent: Int, weeklyPercent: Int, canTakeOver: Bool) {
        let display = UsageFixture.display(
            id: "spare",
            sessionPercent: sessionPercent,
            weeklyPercent: weeklyPercent,
            limits: AccountLimits(session: 70, weekly: 80))
        #expect(rankedIds([display]) == (canTakeOver ? ["spare"] : []))
    }

    @Test("A full window whose reset has passed no longer blocks the account", arguments: UsageWindow.allCases)
    func fullWindowPastItsResetCanTakeOver(window: UsageWindow) {
        let fiveMinutesAgo = UsageFixture.minutesFromNow(-5)
        let display = switch window {
        case .session:
            UsageFixture.display(id: "spare", sessionPercent: 100, sessionResetsAt: fiveMinutesAgo)
        case .weekly:
            UsageFixture.display(id: "spare", weeklyPercent: 100, weeklyResetsAt: fiveMinutesAgo)
        }
        #expect(rankedIds([display]) == ["spare"])
    }
}

@Suite("Candidate ranking")
struct AutoSwitchRankingTests {
    @Test("The account already carrying the login is never a candidate")
    func activeAccountIsExcluded() {
        let displays = [
            UsageFixture.display(id: "active", sessionPercent: 10, isActive: true),
            UsageFixture.display(id: "spare", sessionPercent: 50),
        ]
        #expect(rankedIds(displays) == ["spare"])
    }

    @Test("Comfortable session room beats a sooner weekly reset")
    func comfortableRoomOutranksAnEarlierWeeklyReset() {
        // Seventy leaves exactly twenty points under the ninety limit; seventy-one leaves nineteen.
        let displays = [
            UsageFixture.display(
                id: "tight", sessionPercent: 71, weeklyResetsAt: UsageFixture.daysFromNow(1)),
            UsageFixture.display(
                id: "comfortable", sessionPercent: 70, weeklyResetsAt: UsageFixture.daysFromNow(6)),
        ]
        #expect(rankedIds(displays) == ["comfortable", "tight"])
    }

    @Test("Among comfortable accounts the weekly capacity that expires first is spent first")
    func soonestWeeklyResetWins() {
        let displays = [
            UsageFixture.display(
                id: "later", sessionPercent: 10, weeklyResetsAt: UsageFixture.daysFromNow(5)),
            UsageFixture.display(
                id: "sooner", sessionPercent: 60, weeklyResetsAt: UsageFixture.daysFromNow(2)),
        ]
        #expect(rankedIds(displays) == ["sooner", "later"])
    }

    @Test("A weekly reset already behind us counts as a full week away")
    func pastWeeklyResetSortsAsAFreshWindow() {
        let displays = [
            UsageFixture.display(
                id: "eightDays", sessionPercent: 30, weeklyResetsAt: UsageFixture.daysFromNow(8)),
            UsageFixture.display(
                id: "alreadyReset", sessionPercent: 10, weeklyResetsAt: UsageFixture.daysFromNow(-1)),
            UsageFixture.display(
                id: "twoDays", sessionPercent: 20, weeklyResetsAt: UsageFixture.daysFromNow(2)),
        ]
        #expect(rankedIds(displays) == ["twoDays", "alreadyReset", "eightDays"])
    }

    @Test("An account with no known weekly reset sorts last")
    func missingWeeklyResetSortsLast() {
        let displays = [
            UsageFixture.display(id: "unknownReset", sessionPercent: 5, weeklyResetsAt: nil),
            UsageFixture.display(
                id: "knownReset", sessionPercent: 50, weeklyResetsAt: UsageFixture.daysFromNow(8)),
        ]
        #expect(rankedIds(displays) == ["knownReset", "unknownReset"])
    }

    @Test("More session room under its own limit breaks a tie on weekly reset")
    func sessionRoomBreaksTies() {
        let sharedReset = UsageFixture.daysFromNow(3)
        // Thirty of a ninety limit leaves sixty points; twenty of a seventy limit leaves fifty.
        let displays = [
            UsageFixture.display(
                id: "emptier",
                sessionPercent: 20,
                weeklyResetsAt: sharedReset,
                limits: AccountLimits(session: 70, weekly: 95)),
            UsageFixture.display(id: "roomier", sessionPercent: 30, weeklyResetsAt: sharedReset),
        ]
        #expect(rankedIds(displays) == ["roomier", "emptier"])
    }

    @Test("Accounts tied on every measure fall back to roster order")
    func rosterOrderBreaksExactTies() {
        let sharedReset = UsageFixture.daysFromNow(3)
        let earlierInRoster = UsageFixture.display(
            id: "earlierInRoster",
            sessionPercent: 25,
            weeklyResetsAt: sharedReset,
            displayOrder: 1)
        let laterInRoster = UsageFixture.display(
            id: "laterInRoster",
            sessionPercent: 25,
            weeklyResetsAt: sharedReset,
            displayOrder: 2)
        let expected = ["earlierInRoster", "laterInRoster"]
        #expect(rankedIds([earlierInRoster, laterInRoster]) == expected)
        #expect(rankedIds([laterInRoster, earlierInRoster]) == expected)
    }
}

@Suite("Switch decisions")
struct AutoSwitchDecisionTests {
    /// Two spare accounts; "sooner" is the one the ranking should reach for.
    private let spares = [
        UsageFixture.display(
            id: "later", sessionPercent: 10, weeklyResetsAt: UsageFixture.daysFromNow(5)),
        UsageFixture.display(
            id: "sooner", sessionPercent: 20, weeklyResetsAt: UsageFixture.daysFromNow(2)),
    ]

    private func decide(
        _ displays: [AccountDisplay],
        settings: UsageSettings = UsageFixture.settings(),
        activePace: CurrentPace? = nil,
        lastManualSwitchAt: Date? = nil) -> AutoSwitchPlanner.Decision
    {
        AutoSwitchPlanner.decide(
            displays: displays,
            settings: settings,
            activePace: activePace,
            lastManualSwitchAt: lastManualSwitchAt,
            now: now)
    }

    @Test("With auto-switching off a maxed-out account is left alone")
    func disabledAutoSwitchStays() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 100, isActive: true)]
            + self.spares
        let decision = self.decide(displays, settings: UsageFixture.settings(autoSwitchEnabled: false))
        #expect(decision == .stay)
    }

    @Test("Reaching its own session limit hands the login to the best candidate")
    func sessionAtItsLimitSwitches() {
        let active = UsageFixture.display(
            id: "active",
            sessionPercent: 70,
            isActive: true,
            limits: AccountLimits(session: 70, weekly: 95))
        #expect(
            self.decide([active] + self.spares)
                == .switchTo(accountId: "sooner", reason: .sessionAtLimit(percent: 70, limit: 70)))
    }

    @Test("Reaching its own weekly limit moves the login, whatever the session", arguments: [10, 70])
    func weeklyAtItsLimitSwitches(sessionPercent: Int) {
        // At seventy the session is at its own limit too, and the weekly limit is still the reason.
        let active = UsageFixture.display(
            id: "active",
            sessionPercent: sessionPercent,
            weeklyPercent: 80,
            weeklyResetsAt: UsageFixture.daysFromNow(3),
            isActive: true,
            limits: AccountLimits(session: 70, weekly: 80))
        #expect(
            self.decide([active] + self.spares)
                == .switchTo(accountId: "sooner", reason: .weeklyAtLimit(percent: 80, limit: 80)))
    }

    @Test("A session climbing into its limit before the next check moves the login early")
    func fastClimbSwitchesBeforeTheLimit() {
        // Ten points to go at ten a minute is one minute away.
        let displays = [UsageFixture.display(id: "active", sessionPercent: 80, isActive: true)]
            + self.spares
        let decision = self.decide(
            displays, activePace: CurrentPace(sessionPerHour: 600, weeklyPerHour: nil))
        #expect(
            decision == .switchTo(accountId: "sooner", reason: .sessionClimbing(percent: 80, limit: 90)))
    }

    @Test("A session climbing slowly stays put")
    func slowClimbStays() {
        // Ten points to go at one a minute is ten minutes away, beyond the next check.
        let displays = [UsageFixture.display(id: "active", sessionPercent: 80, isActive: true)]
            + self.spares
        let decision = self.decide(
            displays, activePace: CurrentPace(sessionPerHour: 60, weeklyPerHour: nil))
        #expect(decision == .stay)
    }

    @Test("A cached full session whose window has since reset is not a reason to move")
    func activeSessionPastItsResetStays() {
        let active = UsageFixture.display(
            id: "active",
            sessionPercent: 100,
            sessionResetsAt: UsageFixture.minutesFromNow(-5),
            isActive: true)
        #expect(self.decide([active] + self.spares) == .stay)
    }

    @Test("With nowhere to go the planner reports the reason instead of switching")
    func noCandidateReportsTheReason() {
        let displays = [
            UsageFixture.display(id: "active", sessionPercent: 95, isActive: true),
            UsageFixture.display(id: "alsoSpent", sessionPercent: 95),
            UsageFixture.display(id: "loggedOut", needsRelogin: true),
        ]
        #expect(self.decide(displays) == .noCandidate(reason: .sessionAtLimit(percent: 95, limit: 90)))
    }

    @Test("A switch the user just made by hand is left alone")
    func recentManualSwitchStays() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 95, isActive: true)]
            + self.spares
        let decision = self.decide(displays, lastManualSwitchAt: UsageFixture.minutesFromNow(-2))
        #expect(decision == .stay)
    }

    @Test("The grace period ends exactly when it elapses")
    func manualSwitchGraceIsExclusiveAtItsEnd() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 95, isActive: true)]
            + self.spares
        let elapsed = now.addingTimeInterval(-AutoSwitchPlanner.manualSwitchGrace)
        #expect(
            self.decide(displays, lastManualSwitchAt: elapsed)
                == .switchTo(accountId: "sooner", reason: .sessionAtLimit(percent: 95, limit: 90)))
    }
}

@Suite("Polling pace")
struct AutoSwitchPacingTests {
    private let baseInterval: TimeInterval = 5 * 60

    /// How long the active account may go unchecked, as `AccountManager` asks for it.
    private func interval(
        sessionPercent: Int,
        weeklyPercent: Int = 0,
        pace: CurrentPace?,
        autoSwitchEnabled: Bool = true) -> TimeInterval
    {
        let active = UsageFixture.display(
            id: "active", sessionPercent: sessionPercent, weeklyPercent: weeklyPercent, isActive: true)
        return AutoSwitchPlanner.activeRefreshInterval(
            active: AutoSwitchPlanner.Candidate(display: active, now: now),
            pace: pace,
            settings: UsageFixture.settings(
                refreshInterval: self.baseInterval, autoSwitchEnabled: autoSwitchEnabled))
    }

    @Test("With auto-switching off the base interval stands however fast usage climbs")
    func disabledAutoSwitchUsesTheBaseInterval() {
        let interval = self.interval(
            sessionPercent: 85,
            pace: CurrentPace(sessionPerHour: 600, weeklyPerHour: nil),
            autoSwitchEnabled: false)
        #expect(interval == self.baseInterval)
    }

    @Test(
        "Usage that isn't climbing keeps the base interval",
        arguments: [nil, CurrentPace(sessionPerHour: -40, weeklyPerHour: -40)])
    func noClimbUsesTheBaseInterval(pace: CurrentPace?) {
        #expect(self.interval(sessionPercent: 85, pace: pace) == self.baseInterval)
    }

    @Test("A limit hours away is still polled at the base interval")
    func distantLimitUsesTheBaseInterval() {
        // Eighty points to go at one an hour is eighty hours away.
        let interval = self.interval(
            sessionPercent: 10, pace: CurrentPace(sessionPerHour: 1, weeklyPerHour: nil))
        #expect(interval == self.baseInterval)
    }

    @Test(
        "The nearer limit is polled twice before it arrives",
        arguments: [
            // Ten session points to go at eighty an hour is 450 seconds; the weekly limit is hours off.
            (sessionPercent: 80, weeklyPercent: 50, pace: CurrentPace(sessionPerHour: 80, weeklyPerHour: 10)),
            // Five weekly points to go at forty an hour is 450 seconds; the session limit is hours off.
            (sessionPercent: 50, weeklyPercent: 90, pace: CurrentPace(sessionPerHour: 10, weeklyPerHour: 40)),
        ])
    func nearerLimitPollsAtHalfTheTimeRemaining(sessionPercent: Int, weeklyPercent: Int, pace: CurrentPace) {
        let interval = self.interval(
            sessionPercent: sessionPercent, weeklyPercent: weeklyPercent, pace: pace)
        #expect(interval == 225)
    }

    @Test(
        "A limit seconds away or already reached is polled at the floor",
        arguments: [
            // One point to go at a point a second is one second away.
            (sessionPercent: 89, sessionPerHour: 3600.0),
            // At the limit there is no time left at all.
            (sessionPercent: 90, sessionPerHour: 10.0),
        ])
    func imminentLimitPollsAtTheFloor(sessionPercent: Int, sessionPerHour: Double) {
        let interval = self.interval(
            sessionPercent: sessionPercent,
            pace: CurrentPace(sessionPerHour: sessionPerHour, weeklyPerHour: nil))
        #expect(interval == AutoSwitchPlanner.fastestRefresh)
    }
}
