import Foundation

/// How the fleet forecast reads at a glance.
public struct FleetStatus {
    public enum Level {
        case learning
        case covered
        /// Runs out within the horizon, but not today.
        case tight
        /// Runs out within the day, or already has.
        case short
    }

    public let level: Level
    public let headline: String
    public let detail: String
    /// The expected work no account has room for, when the forecast runs short.
    public let overBudget: String?

    /// A forecast running out sooner than this is already here.
    private static let alreadyOut: TimeInterval = 15 * 60
    private static let soon: TimeInterval = 24 * 60 * 60

    public init(fleet: FleetForecast?, now: Date) {
        guard let fleet else {
            self.level = .learning
            self.headline = "Learning your pace"
            self.detail = "needs about an hour of work"
            self.overBudget = nil
            return
        }
        guard let runsOutAt = fleet.runsOutAt else {
            self.level = .covered
            self.headline = "On pace for the week"
            self.detail = "\(Formatting.workHours(fleet.bankedHours)) banked"
            self.overBudget = nil
            return
        }
        let remaining = runsOutAt.timeIntervalSince(now)
        self.level = remaining < Self.soon ? .short : .tight
        self.headline = remaining < Self.alreadyOut
            ? "Every account is at its limits"
            : "Runs out ~\(Formatting.approximateMoment(runsOutAt, now: now))"
        self.detail = fleet.resumesAt.map { "back \(Formatting.approximateMoment($0, now: now))" } ?? ""
        self.overBudget = "\(Formatting.workHours(fleet.shortfallHours)) over budget in the next 7 days"
    }
}

/// The nearest limit the active account is forecast to reach before its window
/// resets, in a line short enough for the row.
public struct ActiveOutlook {
    /// Under an hour away.
    public let isNear: Bool
    public let text: String

    public init?(display: AccountDisplay, now: Date) {
        guard let forecast = display.insight?.forecast else { return nil }
        let crossings: [(window: UsageWindow, at: Date)] = [
            forecast.sessionLimitAt.map { (UsageWindow.session, $0) },
            forecast.weeklyLimitAt.map { (UsageWindow.weekly, $0) },
        ].compactMap { $0 }
        guard let nearest = crossings.filter({ $0.at > now }).min(by: { $0.at < $1.at }) else { return nil }
        let name = nearest.window == .session ? "Session" : "Weekly"
        let remaining = nearest.at.timeIntervalSince(now)
        self.isNear = remaining < 60 * 60
        self.text = remaining < 24 * 60 * 60
            ? "\(name) limit in ~\(Formatting.duration(remaining)) at this pace"
            : "\(name) limit ~\(Formatting.approximateMoment(nearest.at, now: now)) at this pace"
    }
}

/// How close a usage figure is to the limit the account is held to, which is
/// what its bar's color says.
public enum UsageLevel: Sendable {
    case normal
    /// Within reach of the limit.
    case near
    /// At the limit or past it.
    case over

    /// Against a limit: over once there, near within 15 points of it. Without
    /// one, by how full the window is.
    public init(percent: Int, limit: Int?) {
        if let limit {
            self = percent >= limit ? .over : percent >= limit - 15 ? .near : .normal
        } else {
            self = percent >= 80 ? .over : percent >= 50 ? .near : .normal
        }
    }
}
