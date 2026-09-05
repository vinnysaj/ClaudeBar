import Foundation

/// Estimates how fast an account's session window is filling from its last few
/// usage fetches, so polling and switching can get ahead of a busy session.
struct UsageRateTracker: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        let time: Date
        let percent: Int
    }

    /// Samples older than this no longer describe the current pace.
    static let window: TimeInterval = 30 * 60
    /// Two fetches closer together than this say more about jitter than pace.
    static let minimumSpan: TimeInterval = 30

    private var samplesByAccount: [String: [Sample]] = [:]

    mutating func record(percent: Int, for accountId: String, at time: Date) {
        var samples = self.samplesByAccount[accountId] ?? []
        if let last = samples.last {
            // The same fetch again, or a clock that went backwards: nothing to learn.
            if time <= last.time { return }
            // Usage only falls when the window resets; the old slope is meaningless.
            if percent < last.percent { samples = [] }
        }
        samples.append(Sample(time: time, percent: percent))
        samples.removeAll { time.timeIntervalSince($0.time) > Self.window }
        self.samplesByAccount[accountId] = samples
    }

    mutating func forget(accountId: String) {
        self.samplesByAccount[accountId] = nil
    }

    /// Percentage points per hour over the recent window, or nil without enough
    /// history to say.
    func percentPerHour(for accountId: String, at now: Date) -> Double? {
        let samples = (self.samplesByAccount[accountId] ?? [])
            .filter { now.timeIntervalSince($0.time) <= Self.window }
        guard let first = samples.first, let last = samples.last, first != last else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span >= Self.minimumSpan else { return nil }
        return Double(last.percent - first.percent) / span * 3600
    }
}
