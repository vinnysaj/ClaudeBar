import Foundation
import Testing
@testable import ClaudeBar

private let now = UsageFixture.now

@Suite("Effective usage")
struct EffectiveUsedPercentTests {
    @Test("A window whose reset has passed reads as empty")
    func resetInThePastReadsAsEmpty() {
        let metric = UsageFixture.metric(
            label: "Session", usedPercent: 100, resetsAt: UsageFixture.minutesFromNow(-1))
        #expect(metric.effectiveUsedPercent(at: now) == 0)
    }

    @Test("A reset time exactly at now already counts as reset")
    func resetExactlyAtNowReadsAsEmpty() {
        let metric = UsageFixture.metric(label: "Session", usedPercent: 73, resetsAt: now)
        #expect(metric.effectiveUsedPercent(at: now) == 0)
    }

    @Test("A window still open reports its fetched percentage")
    func resetInTheFutureKeepsTheFetchedPercent() {
        let metric = UsageFixture.metric(
            label: "Session", usedPercent: 73, resetsAt: UsageFixture.minutesFromNow(1))
        #expect(metric.effectiveUsedPercent(at: now) == 73)
    }

    @Test("Without a reset time the fetched percentage stands")
    func missingResetKeepsTheFetchedPercent() {
        let metric = UsageFixture.metric(label: "Extra", usedPercent: 42, resetsAt: nil)
        #expect(metric.effectiveUsedPercent(at: now) == 42)
    }
}

@Suite("Window reset since fetch")
struct WindowResetSinceFetchTests {
    private func usage(
        sessionResetsAt: Date? = nil,
        weeklyResetsAt: Date? = nil,
        fableResetsAt: Date? = nil,
        extraUsageResetsAt: Date? = nil,
        fetchedAt: Date) -> AccountUsage
    {
        UsageFixture.usage(
            session: UsageFixture.metric(label: "Session", usedPercent: 50, resetsAt: sessionResetsAt),
            weekly: UsageFixture.metric(label: "Week", usedPercent: 50, resetsAt: weeklyResetsAt),
            fable: UsageFixture.metric(label: "Fable", usedPercent: 50, resetsAt: fableResetsAt),
            extraUsage: UsageFixture.metric(
                label: "Extra", usedPercent: 50, resetsAt: extraUsageResetsAt),
            fetchedAt: fetchedAt)
    }

    @Test("A session reset between the fetch and now invalidates the cache")
    func sessionResetAfterFetchIsDetected() {
        let usage = self.usage(
            sessionResetsAt: UsageFixture.minutesFromNow(-30),
            fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A weekly reset between the fetch and now invalidates the cache")
    func weeklyResetAfterFetchIsDetected() {
        let usage = self.usage(
            weeklyResetsAt: UsageFixture.minutesFromNow(-30),
            fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A Fable reset between the fetch and now invalidates the cache")
    func fableResetAfterFetchIsDetected() {
        let usage = self.usage(
            fableResetsAt: UsageFixture.minutesFromNow(-30),
            fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("An extra-usage reset is not a limit window and leaves the cache valid")
    func extraUsageResetIsIgnored() {
        let usage = self.usage(
            extraUsageResetsAt: UsageFixture.minutesFromNow(-30),
            fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(!usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A reset that predates the fetch is already reflected in the cache")
    func resetBeforeFetchIsNotDetected() {
        let usage = self.usage(
            sessionResetsAt: UsageFixture.hoursFromNow(-2),
            fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(!usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A reset at the moment of the fetch does not invalidate the cache")
    func resetExactlyAtFetchIsNotDetected() {
        let fetchedAt = UsageFixture.hoursFromNow(-1)
        let usage = self.usage(sessionResetsAt: fetchedAt, fetchedAt: fetchedAt)
        #expect(!usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A reset landing exactly on now invalidates the cache")
    func resetExactlyAtNowIsDetected() {
        let usage = self.usage(sessionResetsAt: now, fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A reset still ahead of us leaves the cache valid")
    func resetInTheFutureIsNotDetected() {
        let usage = self.usage(
            sessionResetsAt: UsageFixture.hoursFromNow(1),
            fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(!usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("Windows with no reset time never invalidate the cache")
    func missingResetTimesAreNotDetected() {
        let usage = self.usage(fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(!usage.hasWindowResetSinceFetch(now: now))
    }
}
