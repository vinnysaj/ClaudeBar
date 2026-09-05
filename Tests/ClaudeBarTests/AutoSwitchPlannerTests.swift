import Foundation
import Testing
@testable import ClaudeBar

private let now = UsageFixture.now
private let threshold = 90

@Suite("Account usability")
struct AutoSwitchUsabilityTests {
    @Test("An account that needs a fresh login cannot take over")
    func accountNeedingReloginIsNotUsable() {
        let display = UsageFixture.display(id: "alpha", sessionPercent: 0, needsRelogin: true)
        #expect(!AutoSwitchPlanner.isUsable(display, threshold: threshold, now: now))
    }

    @Test("An account with no usage fetched yet cannot take over")
    func accountWithoutUsageIsNotUsable() {
        let display = UsageFixture.displayWithoutUsage(id: "alpha")
        #expect(!AutoSwitchPlanner.isUsable(display, threshold: threshold, now: now))
    }

    @Test("An account with room in both windows can take over")
    func accountWithRoomIsUsable() {
        let display = UsageFixture.display(id: "alpha", sessionPercent: 40, weeklyPercent: 60)
        #expect(AutoSwitchPlanner.isUsable(display, threshold: threshold, now: now))
    }

    @Test("An account sitting exactly on the threshold cannot take over")
    func accountAtTheThresholdIsNotUsable() {
        let display = UsageFixture.display(id: "alpha", sessionPercent: threshold)
        #expect(!AutoSwitchPlanner.isUsable(display, threshold: threshold, now: now))
    }

    @Test("An account one point below the threshold can take over")
    func accountJustBelowTheThresholdIsUsable() {
        let display = UsageFixture.display(id: "alpha", sessionPercent: threshold - 1)
        #expect(AutoSwitchPlanner.isUsable(display, threshold: threshold, now: now))
    }

    @Test("A spent weekly window blocks the account")
    func accountWithExhaustedWeeklyIsNotUsable() {
        let display = UsageFixture.display(
            id: "alpha",
            sessionPercent: 0,
            weeklyPercent: 100,
            weeklyResetsAt: UsageFixture.daysFromNow(2))
        #expect(!AutoSwitchPlanner.isUsable(display, threshold: threshold, now: now))
    }

    @Test("A spent weekly window whose reset has passed no longer blocks the account")
    func exhaustedWeeklyThatHasResetIsUsable() {
        let display = UsageFixture.display(
            id: "alpha",
            sessionPercent: 0,
            weeklyPercent: 100,
            weeklyResetsAt: UsageFixture.minutesFromNow(-5))
        #expect(AutoSwitchPlanner.isUsable(display, threshold: threshold, now: now))
    }

    @Test("A full session whose reset has passed no longer blocks the account")
    func fullSessionThatHasResetIsUsable() {
        let display = UsageFixture.display(
            id: "alpha",
            sessionPercent: 100,
            sessionResetsAt: UsageFixture.minutesFromNow(-5))
        #expect(AutoSwitchPlanner.isUsable(display, threshold: threshold, now: now))
    }
}

@Suite("Candidate ranking")
struct AutoSwitchRankingTests {
    private func rankedIds(_ displays: [AccountDisplay]) -> [String] {
        AutoSwitchPlanner.rankedCandidates(displays, threshold: threshold, now: now).map(\.id)
    }

    @Test("The account already carrying the login is never a candidate")
    func activeAccountIsExcluded() {
        let displays = [
            UsageFixture.display(id: "active", sessionPercent: 10, isActive: true),
            UsageFixture.display(id: "spare", sessionPercent: 50),
        ]
        #expect(self.rankedIds(displays) == ["spare"])
    }

    @Test("Unusable accounts are filtered out of the ranking")
    func unusableAccountsAreExcluded() {
        let displays = [
            UsageFixture.display(id: "active", sessionPercent: 95, isActive: true),
            UsageFixture.display(id: "loggedOut", sessionPercent: 0, needsRelogin: true),
            UsageFixture.displayWithoutUsage(id: "neverFetched"),
            UsageFixture.display(id: "sessionSpent", sessionPercent: 90),
            UsageFixture.display(
                id: "weeklySpent",
                sessionPercent: 0,
                weeklyPercent: 100,
                weeklyResetsAt: UsageFixture.daysFromNow(1)),
            UsageFixture.display(id: "spare", sessionPercent: 30),
        ]
        #expect(self.rankedIds(displays) == ["spare"])
    }

    @Test("Comfortable session headroom beats a sooner weekly reset")
    func comfortableHeadroomOutranksAnEarlierWeeklyReset() {
        let comfortableBoundary = threshold - AutoSwitchPlanner.comfortableHeadroom
        let displays = [
            UsageFixture.display(
                id: "tight",
                sessionPercent: comfortableBoundary + 1,
                weeklyResetsAt: UsageFixture.daysFromNow(1)),
            UsageFixture.display(
                id: "comfortable",
                sessionPercent: comfortableBoundary,
                weeklyResetsAt: UsageFixture.daysFromNow(6)),
        ]
        #expect(self.rankedIds(displays) == ["comfortable", "tight"])
    }

    @Test("Among comfortable accounts the weekly capacity that expires first is spent first")
    func soonestWeeklyResetWins() {
        let displays = [
            UsageFixture.display(
                id: "later", sessionPercent: 10, weeklyResetsAt: UsageFixture.daysFromNow(5)),
            UsageFixture.display(
                id: "sooner", sessionPercent: 60, weeklyResetsAt: UsageFixture.daysFromNow(2)),
        ]
        #expect(self.rankedIds(displays) == ["sooner", "later"])
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
        #expect(self.rankedIds(displays) == ["twoDays", "alreadyReset", "eightDays"])
    }

    @Test("An account with no known weekly reset sorts last")
    func missingWeeklyResetSortsLast() {
        let displays = [
            UsageFixture.display(id: "unknownReset", sessionPercent: 5, weeklyResetsAt: nil),
            UsageFixture.display(
                id: "knownReset", sessionPercent: 50, weeklyResetsAt: UsageFixture.daysFromNow(8)),
        ]
        #expect(self.rankedIds(displays) == ["knownReset", "unknownReset"])
    }

    @Test("The emptier session breaks a tie on weekly reset")
    func sessionPercentBreaksTies() {
        let sharedReset = UsageFixture.daysFromNow(3)
        let displays = [
            UsageFixture.display(id: "busier", sessionPercent: 40, weeklyResetsAt: sharedReset),
            UsageFixture.display(id: "emptier", sessionPercent: 10, weeklyResetsAt: sharedReset),
        ]
        #expect(self.rankedIds(displays) == ["emptier", "busier"])
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
        #expect(self.rankedIds([earlierInRoster, laterInRoster]) == expected)
        #expect(self.rankedIds([laterInRoster, earlierInRoster]) == expected)
    }

    @Test("With nothing usable the ranking is empty")
    func noUsableAccountsRanksNothing() {
        let displays = [
            UsageFixture.display(id: "active", sessionPercent: 95, isActive: true),
            UsageFixture.display(id: "spent", sessionPercent: 99),
        ]
        #expect(self.rankedIds(displays).isEmpty)
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
        activeRatePercentPerHour: Double? = nil,
        lastManualSwitchAt: Date? = nil) -> AutoSwitchPlanner.Decision
    {
        AutoSwitchPlanner.decide(
            displays: displays,
            settings: settings,
            activeRatePercentPerHour: activeRatePercentPerHour,
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

    @Test("With no account carrying the login there is nothing to move")
    func noActiveAccountStays() {
        #expect(self.decide(self.spares) == .stay)
    }

    @Test("An active account with no usage fetched yet is left alone")
    func activeAccountWithoutUsageStays() {
        let displays = [UsageFixture.displayWithoutUsage(id: "active", isActive: true)] + self.spares
        #expect(self.decide(displays) == .stay)
    }

    @Test("An active account with room to spare is left alone")
    func activeAccountBelowThresholdStays() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 40, isActive: true)]
            + self.spares
        #expect(self.decide(displays) == .stay)
    }

    @Test("Hitting the session threshold hands the login to the best candidate")
    func sessionAtThresholdSwitches() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 90, isActive: true)]
            + self.spares
        #expect(self.decide(displays) == .switchTo(accountId: "sooner", reason: "session at 90%"))
    }

    @Test("A spent weekly window moves the login even with a quiet session")
    func exhaustedWeeklySwitches() {
        let active = UsageFixture.display(
            id: "active",
            sessionPercent: 5,
            weeklyPercent: 100,
            weeklyResetsAt: UsageFixture.daysFromNow(3),
            isActive: true)
        #expect(
            self.decide([active] + self.spares)
                == .switchTo(accountId: "sooner", reason: "weekly limit used up"))
    }

    @Test("A session climbing into the threshold before the next poll moves the login early")
    func fastClimbSwitchesBeforeTheThreshold() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 70, isActive: true)]
            + self.spares
        let decision = self.decide(displays, activeRatePercentPerHour: 300)
        #expect(decision == .switchTo(accountId: "sooner", reason: "session at 70% and climbing fast"))
    }

    @Test("A session climbing slowly stays put")
    func slowClimbStays() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 70, isActive: true)]
            + self.spares
        #expect(self.decide(displays, activeRatePercentPerHour: 60) == .stay)
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
            UsageFixture.display(id: "loggedOut", sessionPercent: 0, needsRelogin: true),
        ]
        #expect(self.decide(displays) == .noCandidate(reason: "session at 95%"))
    }

    @Test("A switch the user just made by hand is left alone")
    func recentManualSwitchStays() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 95, isActive: true)]
            + self.spares
        let decision = self.decide(displays, lastManualSwitchAt: UsageFixture.minutesFromNow(-2))
        #expect(decision == .stay)
    }

    @Test("Once the grace period is over a manual choice no longer holds the login")
    func manualSwitchStopsHoldingAfterTheGracePeriod() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 95, isActive: true)]
            + self.spares
        let decision = self.decide(displays, lastManualSwitchAt: UsageFixture.minutesFromNow(-6))
        #expect(decision == .switchTo(accountId: "sooner", reason: "session at 95%"))
    }

    @Test("The grace period ends exactly when it elapses")
    func manualSwitchGraceIsExclusiveAtItsEnd() {
        let displays = [UsageFixture.display(id: "active", sessionPercent: 95, isActive: true)]
            + self.spares
        let elapsed = now.addingTimeInterval(-AutoSwitchPlanner.manualSwitchGrace)
        #expect(self.decide(displays, lastManualSwitchAt: elapsed)
            == .switchTo(accountId: "sooner", reason: "session at 95%"))
    }
}

@Suite("Polling pace")
struct AutoSwitchPacingTests {
    @Test("With auto-switching off the base interval stands however fast usage climbs")
    func disabledAutoSwitchUsesTheBaseInterval() {
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 85,
            ratePercentPerHour: 600,
            settings: UsageFixture.settings(refreshInterval: 300, autoSwitchEnabled: false))
        #expect(interval == 300)
    }

    @Test("Without a measured rate the base interval stands")
    func missingRateUsesTheBaseInterval() {
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 85,
            ratePercentPerHour: nil,
            settings: UsageFixture.settings(refreshInterval: 300))
        #expect(interval == 300)
    }

    @Test("A session standing still keeps the base interval")
    func zeroRateUsesTheBaseInterval() {
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 85,
            ratePercentPerHour: 0,
            settings: UsageFixture.settings(refreshInterval: 300))
        #expect(interval == 300)
    }

    @Test("A session that fell back after a reset keeps the base interval")
    func negativeRateUsesTheBaseInterval() {
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 85,
            ratePercentPerHour: -40,
            settings: UsageFixture.settings(refreshInterval: 300))
        #expect(interval == 300)
    }

    @Test("A threshold hours away never polls faster than the base interval")
    func distantThresholdUsesTheBaseInterval() {
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 10,
            ratePercentPerHour: 1,
            settings: UsageFixture.settings(refreshInterval: 300))
        #expect(interval == 300)
    }

    @Test("A threshold minutes away is polled twice before it arrives")
    func nearThresholdPollsAtHalfTheTimeRemaining() {
        // Ten points to go at eighty an hour is 450 seconds of headroom.
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 80,
            ratePercentPerHour: 80,
            settings: UsageFixture.settings(refreshInterval: 300))
        #expect(interval == 225)
    }

    @Test("A session about to hit the threshold still polls no faster than the floor")
    func imminentThresholdIsClampedToTheFloor() {
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 89,
            ratePercentPerHour: 3600,
            settings: UsageFixture.settings(refreshInterval: 300))
        #expect(interval == AutoSwitchPlanner.fastestRefresh)
    }

    @Test("A session already at the threshold polls at the floor")
    func sessionAtTheThresholdPollsAtTheFloor() {
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 90,
            ratePercentPerHour: 10,
            settings: UsageFixture.settings(refreshInterval: 300))
        #expect(interval == AutoSwitchPlanner.fastestRefresh)
    }

    @Test("A session past the threshold polls at the floor")
    func sessionPastTheThresholdPollsAtTheFloor() {
        let interval = AutoSwitchPlanner.activeRefreshInterval(
            sessionPercent: 96,
            ratePercentPerHour: 10,
            settings: UsageFixture.settings(refreshInterval: 300))
        #expect(interval == AutoSwitchPlanner.fastestRefresh)
    }

    @Test("Without a rate the projection is the current reading")
    func projectionWithoutARateIsTheCurrentPercent() {
        #expect(
            AutoSwitchPlanner.projectedSessionPercent(
                from: 50, ratePercentPerHour: nil, over: 300) == 50)
    }

    @Test("A flat or falling rate projects no growth")
    func projectionWithoutGrowthIsTheCurrentPercent() {
        #expect(
            AutoSwitchPlanner.projectedSessionPercent(from: 50, ratePercentPerHour: 0, over: 300) == 50)
        #expect(
            AutoSwitchPlanner.projectedSessionPercent(from: 50, ratePercentPerHour: -30, over: 300)
                == 50)
    }

    @Test("The projection adds the growth expected over the interval")
    func projectionAddsTheExpectedGrowth() {
        // A hundred points an hour over five minutes is eight and a third points.
        #expect(
            AutoSwitchPlanner.projectedSessionPercent(from: 50, ratePercentPerHour: 100, over: 300)
                == 58)
        #expect(
            AutoSwitchPlanner.projectedSessionPercent(from: 70, ratePercentPerHour: 300, over: 300)
                == 95)
    }

    @Test("A projection may run past a full window")
    func projectionCanExceedFull() {
        #expect(
            AutoSwitchPlanner.projectedSessionPercent(from: 80, ratePercentPerHour: 120, over: 1800)
                == 140)
    }
}
