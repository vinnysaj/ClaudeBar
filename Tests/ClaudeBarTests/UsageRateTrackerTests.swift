import Foundation
import Testing
@testable import ClaudeBar

private let start = UsageFixture.now

/// Rates are computed in floating point, so compare with a tolerance far tighter
/// than any behaviour change would produce.
private func expectRate(_ actual: Double?, isCloseTo expected: Double) throws {
    let rate = try #require(actual)
    #expect(abs(rate - expected) < 0.000_001)
}

@Suite("Usage rate tracker")
struct UsageRateTrackerTests {
    @Test("One sample says nothing about pace")
    func singleSampleHasNoRate() {
        var tracker = UsageRateTracker()
        tracker.record(percent: 40, for: "alpha", at: start)
        #expect(tracker.percentPerHour(for: "alpha", at: start) == nil)
    }

    @Test("An account never sampled has no rate")
    func unknownAccountHasNoRate() {
        let tracker = UsageRateTracker()
        #expect(tracker.percentPerHour(for: "alpha", at: start) == nil)
    }

    @Test("Ten points over six minutes is a hundred points an hour")
    func twoSamplesGiveTheHourlyRate() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 40, for: "alpha", at: start)
        tracker.record(percent: 50, for: "alpha", at: start.addingTimeInterval(6 * 60))
        try expectRate(
            tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(6 * 60)),
            isCloseTo: 100)
    }

    @Test("Samples exactly thirty seconds apart are far enough apart to count")
    func minimumSpanIsInclusive() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 40, for: "alpha", at: start)
        tracker.record(percent: 41, for: "alpha", at: start.addingTimeInterval(30))
        try expectRate(
            tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(30)),
            isCloseTo: 120)
    }

    @Test("Samples closer than thirty seconds are jitter, not pace")
    func spanBelowTheMinimumHasNoRate() {
        var tracker = UsageRateTracker()
        tracker.record(percent: 40, for: "alpha", at: start)
        tracker.record(percent: 60, for: "alpha", at: start.addingTimeInterval(20))
        #expect(tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(20)) == nil)
    }

    @Test("Usage that has not moved reports a rate of zero, not nothing")
    func flatUsageReportsZero() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 40, for: "alpha", at: start)
        tracker.record(percent: 40, for: "alpha", at: start.addingTimeInterval(120))
        try expectRate(
            tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(120)),
            isCloseTo: 0)
    }

    @Test("The rate spans the whole history, not just the last pair")
    func rateUsesTheOldestAndNewestSamples() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 0, for: "alpha", at: start)
        tracker.record(percent: 50, for: "alpha", at: start.addingTimeInterval(60))
        tracker.record(percent: 60, for: "alpha", at: start.addingTimeInterval(120))
        try expectRate(
            tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(120)),
            isCloseTo: 1800)
    }

    @Test("A drop in usage means the window reset, so the old slope is discarded")
    func usageDropClearsTheHistory() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 50, for: "alpha", at: start)
        tracker.record(percent: 60, for: "alpha", at: start.addingTimeInterval(60))
        tracker.record(percent: 5, for: "alpha", at: start.addingTimeInterval(120))
        #expect(tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(120)) == nil)

        tracker.record(percent: 15, for: "alpha", at: start.addingTimeInterval(180))
        try expectRate(
            tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(180)),
            isCloseTo: 600)
    }

    @Test("Recording drops samples that have aged out of the window")
    func recordingEvictsSamplesOlderThanTheWindow() {
        var tracker = UsageRateTracker()
        tracker.record(percent: 20, for: "alpha", at: start)
        let wellPastTheWindow = start.addingTimeInterval(UsageRateTracker.window + 60)
        tracker.record(percent: 30, for: "alpha", at: wellPastTheWindow)
        #expect(tracker.percentPerHour(for: "alpha", at: wellPastTheWindow) == nil)
    }

    @Test("Reading drops samples that have aged out since they were recorded")
    func readingIgnoresSamplesOlderThanTheWindow() {
        var tracker = UsageRateTracker()
        tracker.record(percent: 20, for: "alpha", at: start)
        tracker.record(percent: 30, for: "alpha", at: start.addingTimeInterval(120))
        let muchLater = start.addingTimeInterval(UsageRateTracker.window + 100)
        #expect(tracker.percentPerHour(for: "alpha", at: muchLater) == nil)
    }

    @Test("Re-recording the same instant leaves the pace untouched")
    func sampleAtTheSameInstantIsIgnored() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 50, for: "alpha", at: start)
        tracker.record(percent: 60, for: "alpha", at: start.addingTimeInterval(60))
        tracker.record(percent: 99, for: "alpha", at: start.addingTimeInterval(60))
        try expectRate(
            tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(60)),
            isCloseTo: 600)
    }

    @Test("A sample from before the last one leaves the pace untouched")
    func sampleFromThePastIsIgnored() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 50, for: "alpha", at: start)
        tracker.record(percent: 60, for: "alpha", at: start.addingTimeInterval(60))
        tracker.record(percent: 99, for: "alpha", at: start.addingTimeInterval(30))
        try expectRate(
            tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(60)),
            isCloseTo: 600)
    }

    @Test("Forgetting an account throws away its history")
    func forgetClearsTheHistory() {
        var tracker = UsageRateTracker()
        tracker.record(percent: 50, for: "alpha", at: start)
        tracker.record(percent: 60, for: "alpha", at: start.addingTimeInterval(60))
        tracker.forget(accountId: "alpha")
        #expect(tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(60)) == nil)
    }

    @Test("Forgetting one account leaves the others alone")
    func forgetOnlyAffectsTheNamedAccount() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 50, for: "alpha", at: start)
        tracker.record(percent: 60, for: "alpha", at: start.addingTimeInterval(60))
        tracker.record(percent: 10, for: "beta", at: start)
        tracker.record(percent: 15, for: "beta", at: start.addingTimeInterval(60))
        tracker.forget(accountId: "alpha")
        #expect(tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(60)) == nil)
        try expectRate(
            tracker.percentPerHour(for: "beta", at: start.addingTimeInterval(60)),
            isCloseTo: 300)
    }

    @Test("Each account keeps its own pace")
    func accountsAreTrackedIndependently() throws {
        var tracker = UsageRateTracker()
        tracker.record(percent: 0, for: "alpha", at: start)
        tracker.record(percent: 20, for: "alpha", at: start.addingTimeInterval(120))
        tracker.record(percent: 0, for: "beta", at: start)
        tracker.record(percent: 5, for: "beta", at: start.addingTimeInterval(120))
        try expectRate(
            tracker.percentPerHour(for: "alpha", at: start.addingTimeInterval(120)),
            isCloseTo: 600)
        try expectRate(
            tracker.percentPerHour(for: "beta", at: start.addingTimeInterval(120)),
            isCloseTo: 150)
    }
}
