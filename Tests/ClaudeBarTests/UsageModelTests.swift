import Foundation
import Testing
@testable import ClaudeBar

private let now = UsageFixture.now

@Suite("Effective usage")
struct EffectiveUsedPercentTests {
    @Test("A window reads as empty from the instant its reset time arrives")
    func resetExactlyAtNowReadsAsEmpty() {
        let metric = UsageFixture.metric(label: "Session", usedPercent: 73, resetsAt: now)
        #expect(metric.effectiveUsedPercent(at: now) == 0)
    }

    @Test("Without a reset time the fetched percentage stands")
    func missingResetKeepsTheFetchedPercent() {
        let metric = UsageFixture.metric(label: "Extra", usedPercent: 42, resetsAt: nil)
        #expect(metric.effectiveUsedPercent(at: now) == 42)
    }
}

@Suite("Window reset since fetch")
struct WindowResetSinceFetchTests {
    /// Usage with every limit window open, of which only `window` has a reset time.
    private func usage(
        window: WritableKeyPath<AccountUsage, UsageMetric?> = \.session,
        resetsAt: Date,
        fetchedAt: Date) -> AccountUsage
    {
        var usage = UsageFixture.usage(
            session: UsageFixture.metric(label: "Session", usedPercent: 50, resetsAt: nil),
            weekly: UsageFixture.metric(label: "Week", usedPercent: 50, resetsAt: nil),
            fable: UsageFixture.metric(label: "Fable", usedPercent: 50, resetsAt: nil),
            fetchedAt: fetchedAt)
        usage[keyPath: window] = UsageFixture.metric(label: "Limit", usedPercent: 50, resetsAt: resetsAt)
        return usage
    }

    @Test(
        "A reset in any limit window between the fetch and now invalidates the cache",
        arguments: [\AccountUsage.session, \.weekly, \.fable])
    func limitWindowResetAfterFetchIsDetected(
        window: WritableKeyPath<AccountUsage, UsageMetric?> & Sendable)
    {
        let usage = self.usage(
            window: window,
            resetsAt: UsageFixture.minutesFromNow(-30),
            fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A reset at the moment of the fetch does not invalidate the cache")
    func resetExactlyAtFetchIsNotDetected() {
        let fetchedAt = UsageFixture.hoursFromNow(-1)
        let usage = self.usage(resetsAt: fetchedAt, fetchedAt: fetchedAt)
        #expect(!usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A reset landing exactly on now invalidates the cache")
    func resetExactlyAtNowIsDetected() {
        let usage = self.usage(resetsAt: now, fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(usage.hasWindowResetSinceFetch(now: now))
    }

    @Test("A reset still ahead of us leaves the cache valid")
    func resetInTheFutureIsNotDetected() {
        let usage = self.usage(
            resetsAt: UsageFixture.hoursFromNow(1),
            fetchedAt: UsageFixture.hoursFromNow(-1))
        #expect(!usage.hasWindowResetSinceFetch(now: now))
    }
}

@Suite("Limit steps")
struct LimitStepTests {
    @Test(
        "A limit saved between choices steps to the nearest choice either way",
        arguments: [(93, true, 95), (93, false, 90)])
    func offScaleLimitStepsOntoTheScale(percent: Int, up: Bool, expected: Int) {
        #expect(AccountLimits.choice(steppingFrom: percent, up: up) == expected)
    }
}
