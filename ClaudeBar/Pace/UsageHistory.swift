import Foundation
import os

/// The limit-window figures from one usage fetch.
struct UsageReading: Sendable, Codable, Equatable {
    var sessionPercent: Int?
    var sessionResetsAt: Date?
    var weeklyPercent: Int?
    var weeklyResetsAt: Date?

    /// Reset times from the API can drift by a few seconds between fetches of
    /// the same window; anything closer than this is the same reset.
    static let resetTolerance: TimeInterval = 5 * 60

    init(sessionPercent: Int?, sessionResetsAt: Date?, weeklyPercent: Int?, weeklyResetsAt: Date?) {
        self.sessionPercent = sessionPercent
        self.sessionResetsAt = sessionResetsAt
        self.weeklyPercent = weeklyPercent
        self.weeklyResetsAt = weeklyResetsAt
    }

    init(usage: AccountUsage) {
        self.init(
            sessionPercent: usage.session?.usedPercent,
            sessionResetsAt: usage.session?.resetsAt,
            weeklyPercent: usage.weekly?.usedPercent,
            weeklyResetsAt: usage.weekly?.resetsAt)
    }

    /// The same figures in the same windows.
    func matches(_ other: UsageReading) -> Bool {
        self.sessionPercent == other.sessionPercent
            && self.weeklyPercent == other.weeklyPercent
            && Self.sameReset(self.sessionResetsAt, other.sessionResetsAt)
            && Self.sameReset(self.weeklyResetsAt, other.weeklyResetsAt)
    }

    static func sameReset(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < Self.resetTolerance
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionPercent = "s"
        case sessionResetsAt = "sr"
        case weeklyPercent = "w"
        case weeklyResetsAt = "wr"
    }
}

/// Which limit window a figure belongs to.
enum UsageWindow: Sendable, CaseIterable {
    case session
    case weekly

    func percent(in reading: UsageReading) -> Int? {
        switch self {
        case .session: return reading.sessionPercent
        case .weekly: return reading.weeklyPercent
        }
    }

    func resetsAt(in reading: UsageReading) -> Date? {
        switch self {
        case .session: return reading.sessionResetsAt
        case .weekly: return reading.weeklyResetsAt
        }
    }

    /// Whether two readings, earlier then later, fall in the same window: the
    /// same reset time and no drop in usage (usage only falls when a window resets).
    func isSameWindow(_ earlier: UsageReading, _ later: UsageReading) -> Bool {
        guard UsageReading.sameReset(self.resetsAt(in: earlier), self.resetsAt(in: later)) else { return false }
        guard let before = self.percent(in: earlier), let after = self.percent(in: later) else { return true }
        return after >= before
    }

    /// Percentage points used between two readings, earlier then later. Across a
    /// reset, everything the new window shows was used after the earlier reading.
    func gain(from earlier: UsageReading, to later: UsageReading) -> Double {
        guard let after = self.percent(in: later) else { return 0 }
        guard self.isSameWindow(earlier, later) else { return Double(after) }
        return Double(after - (self.percent(in: earlier) ?? 0))
    }
}

/// A stretch over which an account's reading held steady. Consecutive fetches
/// with the same figures extend one run instead of piling up, so the history
/// stays small while keeping every change and when it was seen.
struct UsageRun: Sendable, Codable, Equatable {
    var reading: UsageReading
    var firstSeen: Date
    var lastSeen: Date

    private enum CodingKeys: String, CodingKey {
        case reading = "r"
        case firstSeen = "f"
        case lastSeen = "l"
    }
}

/// A charted usage figure.
struct UsagePoint: Sendable, Equatable {
    let time: Date
    let percent: Double
}

/// How fast an account's usage moved over the last little while, in
/// percentage points per wall-clock hour. Nil for a window with too little
/// recent history to say.
struct CurrentPace: Sendable, Equatable {
    let sessionPerHour: Double?
    let weeklyPerHour: Double?

    func perHour(_ window: UsageWindow) -> Double? {
        switch window {
        case .session: return self.sessionPerHour
        case .weekly: return self.weeklyPerHour
        }
    }
}

/// Every usage reading ClaudeBar has fetched, per account, over the last few
/// weeks. Pace and forecasts are learned from it.
struct UsageHistory: Sendable, Codable {
    /// Long enough to see the same weekday several times over.
    static let retention: TimeInterval = 35 * 24 * 60 * 60
    /// Fetches further apart than this leave a gap nobody watched: the app was
    /// quit or the Mac asleep. Comfortably above the slowest refresh schedule.
    static let maximumObservedGap: TimeInterval = 45 * 60
    /// How far back the current pace looks.
    static let paceWindow: TimeInterval = 30 * 60
    /// Less history than this says more about rounding than about pace: a
    /// one-point tick a minute apart would read as sixty points an hour.
    static let minimumPaceSpan: TimeInterval = 5 * 60

    private(set) var runsByAccount: [String: [UsageRun]]

    static let empty = UsageHistory(runsByAccount: [:])

    var isEmpty: Bool { self.runsByAccount.values.allSatisfy(\.isEmpty) }

    func runs(for accountId: String) -> [UsageRun] {
        self.runsByAccount[accountId] ?? []
    }

    mutating func record(_ reading: UsageReading, for accountId: String, at time: Date) {
        var runs = self.runsByAccount[accountId] ?? []
        if let last = runs.last {
            // The same fetch again, or a clock that went backwards: nothing to learn.
            guard time > last.lastSeen else { return }
            if last.reading.matches(reading), time.timeIntervalSince(last.lastSeen) <= Self.maximumObservedGap {
                runs[runs.count - 1].lastSeen = time
                // Keep the newest reset times so small drifts don't accumulate.
                runs[runs.count - 1].reading = reading
                self.runsByAccount[accountId] = runs
                return
            }
        }
        runs.append(UsageRun(reading: reading, firstSeen: time, lastSeen: time))
        let cutoff = time.addingTimeInterval(-Self.retention)
        runs.removeAll { $0.lastSeen < cutoff }
        self.runsByAccount[accountId] = runs
    }

    mutating func forget(accountId: String) {
        self.runsByAccount[accountId] = nil
    }

    /// Recent pace for each window, measured from the oldest to the newest
    /// reading of the window currently open.
    func currentPace(for accountId: String, at now: Date) -> CurrentPace? {
        let runs = self.runs(for: accountId)
        guard !runs.isEmpty else { return nil }
        return CurrentPace(
            sessionPerHour: Self.recentSlope(runs, window: .session, now: now),
            weeklyPerHour: Self.recentSlope(runs, window: .weekly, now: now))
    }

    private static func recentSlope(_ runs: [UsageRun], window: UsageWindow, now: Date) -> Double? {
        guard let latest = runs.last,
              let latestPercent = window.percent(in: latest.reading),
              now.timeIntervalSince(latest.lastSeen) <= Self.paceWindow
        else { return nil }
        let windowStart = now.addingTimeInterval(-Self.paceWindow)

        // Walk back through runs of the same window that overlap the pace window.
        var earliest = latest
        for run in runs.dropLast().reversed() {
            guard run.lastSeen >= windowStart, window.isSameWindow(run.reading, earliest.reading) else { break }
            earliest = run
        }
        guard let earliestPercent = window.percent(in: earliest.reading) else { return nil }
        let start = max(earliest.firstSeen, windowStart)
        let span = latest.lastSeen.timeIntervalSince(start)
        guard span >= Self.minimumPaceSpan else { return nil }
        return Double(latestPercent - earliestPercent) / span * 3600
    }

    /// Weekly usage recorded in the window that resets at `resetsAt`, for charting.
    func weeklyPoints(for accountId: String, windowResettingAt resetsAt: Date) -> [UsagePoint] {
        self.runs(for: accountId)
            .filter { UsageReading.sameReset($0.reading.weeklyResetsAt, resetsAt) }
            .flatMap { run -> [UsagePoint] in
                guard let percent = run.reading.weeklyPercent else { return [] }
                let first = UsagePoint(time: run.firstSeen, percent: Double(percent))
                guard run.lastSeen > run.firstSeen else { return [first] }
                return [first, UsagePoint(time: run.lastSeen, percent: Double(percent))]
            }
    }

    // MARK: - Persistence

    private static let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "history")

    /// Application Support rather than Caches: weeks of history can't be refetched.
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("usage-history.json")
    }

    static func load() -> UsageHistory {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(UsageHistory.self, from: data)
        } catch {
            // Starting over loses the learned pace but nothing else; the next
            // save replaces the unreadable file.
            Self.logger.error("Usage history unreadable, starting fresh: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }

    func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Saving usage history failed: \(String(describing: error), privacy: .public)")
        }
    }
}
