import Foundation

public struct UsageMetric: Sendable, Codable {
    public let label: String
    public let usedPercent: Int
    public let resetsAt: Date?
    public let spentDescription: String?
    public let isUnlimited: Bool

    /// Usage as it stands now. A window whose reset time has passed is empty even
    /// though the last fetch still says otherwise; the next fetch confirms it.
    public func effectiveUsedPercent(at now: Date) -> Int {
        if let resetsAt = self.resetsAt, resetsAt <= now { return 0 }
        return self.usedPercent
    }
}

public struct CostSnapshot: Sendable, Codable {
    /// How far back `hours` reaches: a week, long enough to compare sessions.
    public static let hourlyWindow: TimeInterval = 7 * 24 * 60 * 60

    public let todayCostUSD: Double
    public let todayTokens: Int
    public let last30DaysCostUSD: Double
    public let last30DaysTokens: Int
    /// Models in the window ClaudeBar had no rates for. Their tokens are in the
    /// totals above but their cost is not, so the figures understate by their share.
    public let unpricedModels: [String]
    /// Every local clock hour with logged usage over the last `hourlyWindow`, oldest first.
    public let hours: [HourlyUsage]

    /// Where the 30-day totals start counting: the start of the local day 30 days before today.
    public static func windowStart(now: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
    }
}

extension CostSnapshot {
    /// Totals as of `now` over hours scanned from the logs, in `calendar`'s time zone.
    public init(summarizing scanned: some Sequence<HourlyUsage>, now: Date, calendar: Calendar) {
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = Self.windowStart(now: now, calendar: calendar)
        let hourlyStart = now.addingTimeInterval(-Self.hourlyWindow)
        var todayCost: Double = 0
        var todayTokens = 0
        var totalCost: Double = 0
        var totalTokens = 0
        var unpricedModels: Set<String> = []
        var recentHours: [HourlyUsage] = []
        for hour in scanned where hour.start >= windowStart {
            totalCost += hour.cost
            totalTokens += hour.tokens
            unpricedModels.formUnion(hour.unpricedModels)
            if hour.start >= startOfToday {
                todayCost += hour.cost
                todayTokens += hour.tokens
            }
            if hour.end > hourlyStart {
                recentHours.append(hour)
            }
        }
        self.init(
            todayCostUSD: todayCost,
            todayTokens: todayTokens,
            last30DaysCostUSD: totalCost,
            last30DaysTokens: totalTokens,
            unpricedModels: unpricedModels.sorted(),
            hours: recentHours.sorted { $0.start < $1.start })
    }

    /// Snapshots cached before hourly figures existed decode without them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.todayCostUSD = try container.decode(Double.self, forKey: .todayCostUSD)
        self.todayTokens = try container.decode(Int.self, forKey: .todayTokens)
        self.last30DaysCostUSD = try container.decode(Double.self, forKey: .last30DaysCostUSD)
        self.last30DaysTokens = try container.decode(Int.self, forKey: .last30DaysTokens)
        self.unpricedModels = try container.decode([String].self, forKey: .unpricedModels)
        self.hours = try container.decodeIfPresent([HourlyUsage].self, forKey: .hours) ?? []
    }
}

/// Tokens and estimated cost logged in one local clock hour.
public struct HourlyUsage: Sendable, Codable, Equatable {
    public static let length: TimeInterval = 60 * 60

    /// Where the hour starts in the time zone the logs were scanned in.
    public let start: Date
    public var cost: Double
    public var tokens: Int
    /// Models seen this hour that the pricing table had no rates for. Their tokens
    /// are in `tokens`; their cost is not in `cost`.
    public var unpricedModels: [String]

    public var end: Date { self.start.addingTimeInterval(Self.length) }

    /// Adds another tally of the same hour.
    public mutating func add(_ other: HourlyUsage) {
        self.cost += other.cost
        self.tokens += other.tokens
        for model in other.unpricedModels where !self.unpricedModels.contains(model) {
            self.unpricedModels.append(model)
        }
    }
}

/// One managed Anthropic account. `id` is the account UUID from the OAuth profile.
public struct Account: Sendable, Codable, Identifiable {
    public let id: String
    public var email: String
    public var organizationName: String?
    /// Verbatim JSON of the `oauthAccount` object from ~/.claude.json, captured when
    /// this account was last live; written back on switch so the CLI sees consistent
    /// account metadata.
    public var oauthAccountRaw: Data?
    public var displayOrder: Int
    public var needsRelogin: Bool
    public var preferences: AccountPreferences
}

extension Account {
    /// Rosters saved before per-account preferences existed decode with the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.email = try container.decode(String.self, forKey: .email)
        self.organizationName = try container.decodeIfPresent(String.self, forKey: .organizationName)
        self.oauthAccountRaw = try container.decodeIfPresent(Data.self, forKey: .oauthAccountRaw)
        self.displayOrder = try container.decode(Int.self, forKey: .displayOrder)
        self.needsRelogin = try container.decode(Bool.self, forKey: .needsRelogin)
        self.preferences = try container.decodeIfPresent(AccountPreferences.self, forKey: .preferences)
            ?? .default
    }
}

/// Per-account choices that override the global usage settings.
public struct AccountPreferences: Sendable, Codable, Equatable {
    /// Session percent this account stops taking work at; nil follows the global default.
    public var sessionLimit: Int?
    /// Weekly percent this account stops taking work at; nil follows the global
    /// default. Setting it below 100 keeps the rest in reserve, e.g. for claude.ai.
    public var weeklyLimit: Int?
    /// Whether auto-switching may move the login onto this account.
    public var allowsAutoSwitch: Bool

    public static let `default` = AccountPreferences(sessionLimit: nil, weeklyLimit: nil, allowsAutoSwitch: true)
}

/// The usage, in percent, an account takes work up to. Auto-switching moves the
/// login off an account at either limit and never onto one near them.
public struct AccountLimits: Sendable, Codable, Equatable {
    public let session: Int
    public let weekly: Int

    /// Every percent a limit can be set to: steps of 5, then each point from 95 to 100.
    public static let choices = Array(stride(from: 10, to: 95, by: 5)) + Array(95...100)

    /// The choice one step above or below `percent`, or nil past either end. A percent
    /// between choices, which older builds could save, steps to the nearest one that way.
    public static func choice(steppingFrom percent: Int, up: Bool) -> Int? {
        up ? Self.choices.first { $0 > percent } : Self.choices.last { $0 < percent }
    }

    public func percent(_ window: UsageWindow) -> Int {
        switch window {
        case .session: return self.session
        case .weekly: return self.weekly
        }
    }
}

/// Persisted roster (Application Support/ClaudeBar/accounts.json).
public struct AccountsState: Sendable, Codable {
    public var accounts: [Account]
    public var activeAccountUuid: String?

    public static let empty = AccountsState(accounts: [], activeAccountUuid: nil)
}

public struct AccountUsage: Sendable, Codable {
    public var session: UsageMetric?
    public var weekly: UsageMetric?
    public var fable: UsageMetric?
    public var extraUsage: UsageMetric?
    public var fetchedAt: Date

    /// A limit window rolled over after this was fetched, so its cached figures
    /// are wrong no matter how recent the fetch.
    public func hasWindowResetSinceFetch(now: Date) -> Bool {
        [self.session, self.weekly, self.fable].contains { metric in
            guard let resetsAt = metric?.resetsAt else { return false }
            return resetsAt > self.fetchedAt && resetsAt <= now
        }
    }
}

/// Persisted usage cache (Caches/ClaudeBar/usage-cache-v2.json).
public struct UsageCacheFile: Sendable, Codable {
    public var usageByAccount: [String: AccountUsage]
    public var cost: CostSnapshot?

    public static let empty = UsageCacheFile(usageByAccount: [:], cost: nil)
}

/// Everything the UI needs to render one account row.
public struct AccountDisplay: Sendable, Codable, Identifiable {
    public let account: Account
    public let usage: AccountUsage?
    public let isActive: Bool
    public var isRecommended: Bool
    public let isStale: Bool
    /// The limits this account is held to, with the global defaults filled in.
    public let limits: AccountLimits
    /// Pace and forecast. Only the UI snapshot computes these; the planner has no use for them.
    public var insight: AccountInsight?

    public var id: String { self.account.id }
}

/// What the usage history says about one account.
public struct AccountInsight: Sendable, Codable {
    /// How fast usage moved over the last half hour.
    public let currentPace: CurrentPace?
    /// How fast this account's limits fill per hour of active work.
    public let typicalPace: TypicalPace?
    /// The typical pace is pooled across every account, for want of enough of this one's own.
    public let isPacePooled: Bool
    /// Where usage is headed if all work went to this account; nil without a pace.
    public let forecast: AccountForecast?
    /// Hours of work the remaining weekly room covers at the typical pace.
    public let bankedHours: Double?
    /// Weekly usage recorded since the current weekly window opened.
    public let weeklyHistory: [UsagePoint]
}

/// Why the live login moved to another account.
public enum SwitchTrigger: Sendable {
    case user
    /// Auto-switching, with the condition on the previous account that caused it.
    case automatic(reason: SwitchReason)
}

/// The condition on the active account that made auto-switching move the login.
public enum SwitchReason: Sendable, Equatable, CustomStringConvertible {
    case sessionAtLimit(percent: Int, limit: Int)
    case weeklyAtLimit(percent: Int, limit: Int)
    /// Usage would cross the limit before the next check.
    case sessionClimbing(percent: Int, limit: Int)
    case weeklyClimbing(percent: Int, limit: Int)

    /// Completes a sentence that starts with the account's email.
    public var description: String {
        switch self {
        case .sessionAtLimit(let percent, let limit):
            return "reached its \(limit)% session limit (at \(percent)%)"
        case .weeklyAtLimit(let percent, let limit):
            return "reached its \(limit)% weekly limit (at \(percent)%)"
        case .sessionClimbing(let percent, let limit):
            return "was about to reach its \(limit)% session limit (at \(percent)% and climbing)"
        case .weeklyClimbing(let percent, let limit):
            return "was about to reach its \(limit)% weekly limit (at \(percent)% and climbing)"
        }
    }
}

public enum BannerKind: Sendable, Codable {
    case info
    case warning
    case error
}

public struct Banner: Sendable, Codable, Equatable {
    public let kind: BannerKind
    public let message: String
}

/// AccountManager's state as the panel, the tray and the CLI render it.
public struct AccountsSnapshot: Sendable, Codable {
    public let displays: [AccountDisplay]
    public let banner: Banner?
    public let cost: CostSnapshot?
    public let updatedAt: Date?
    /// Whether the accounts together carry the expected work; nil until the
    /// history holds enough work to measure a pace.
    public let fleet: FleetForecast?
    /// When the user tends to work: the configured schedule, reshaped by
    /// whatever history there is so far.
    public let activity: ActivityProfile
}
