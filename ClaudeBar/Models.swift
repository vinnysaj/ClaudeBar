import Foundation

struct UsageMetric: Sendable, Codable {
    let label: String
    let usedPercent: Int
    let resetsAt: Date?
    let spentDescription: String?
    let isUnlimited: Bool

    /// Usage as it stands now. A window whose reset time has passed is empty even
    /// though the last fetch still says otherwise; the next fetch confirms it.
    func effectiveUsedPercent(at now: Date) -> Int {
        if let resetsAt = self.resetsAt, resetsAt <= now { return 0 }
        return self.usedPercent
    }
}

struct CostSnapshot: Sendable, Codable {
    /// How far back `hours` reaches: a week, long enough to compare sessions.
    static let hourlyWindow: TimeInterval = 7 * 24 * 60 * 60

    let todayCostUSD: Double
    let todayTokens: Int
    let last30DaysCostUSD: Double
    let last30DaysTokens: Int
    /// Models in the window ClaudeBar had no rates for. Their tokens are in the
    /// totals above but their cost is not, so the figures understate by their share.
    let unpricedModels: [String]
    /// Every local clock hour with logged usage over the last `hourlyWindow`, oldest first.
    let hours: [HourlyUsage]

    /// Where the 30-day totals start counting: the start of the local day 30 days before today.
    static func windowStart(now: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
    }
}

extension CostSnapshot {
    /// Totals as of `now` over hours scanned from the logs, in `calendar`'s time zone.
    init(summarizing scanned: some Sequence<HourlyUsage>, now: Date, calendar: Calendar) {
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
    init(from decoder: Decoder) throws {
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
struct HourlyUsage: Sendable, Codable, Equatable {
    static let length: TimeInterval = 60 * 60

    /// Where the hour starts in the time zone the logs were scanned in.
    let start: Date
    var cost: Double
    var tokens: Int
    /// Models seen this hour that the pricing table had no rates for. Their tokens
    /// are in `tokens`; their cost is not in `cost`.
    var unpricedModels: [String]

    var end: Date { self.start.addingTimeInterval(Self.length) }

    /// Adds another tally of the same hour.
    mutating func add(_ other: HourlyUsage) {
        self.cost += other.cost
        self.tokens += other.tokens
        for model in other.unpricedModels where !self.unpricedModels.contains(model) {
            self.unpricedModels.append(model)
        }
    }
}

/// One managed Anthropic account. `id` is the account UUID from the OAuth profile.
struct Account: Sendable, Codable, Identifiable {
    let id: String
    var email: String
    var organizationName: String?
    /// Verbatim JSON of the `oauthAccount` object from ~/.claude.json, captured when
    /// this account was last live; written back on switch so the CLI sees consistent
    /// account metadata.
    var oauthAccountRaw: Data?
    var displayOrder: Int
    var needsRelogin: Bool
    var preferences: AccountPreferences
}

extension Account {
    /// Rosters saved before per-account preferences existed decode with the defaults.
    init(from decoder: Decoder) throws {
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
struct AccountPreferences: Sendable, Codable, Equatable {
    /// Session percent this account stops taking work at; nil follows the global default.
    var sessionLimit: Int?
    /// Weekly percent this account stops taking work at; nil follows the global
    /// default. Setting it below 100 keeps the rest in reserve, e.g. for claude.ai.
    var weeklyLimit: Int?
    /// Whether auto-switching may move the login onto this account.
    var allowsAutoSwitch: Bool

    static let `default` = AccountPreferences(sessionLimit: nil, weeklyLimit: nil, allowsAutoSwitch: true)
    static let limitRange = 10...100
    static let limitStep = 5
}

/// The usage, in percent, an account takes work up to. Auto-switching moves the
/// login off an account at either limit and never onto one near them.
struct AccountLimits: Sendable, Equatable {
    let session: Int
    let weekly: Int

    func percent(_ window: UsageWindow) -> Int {
        switch window {
        case .session: return self.session
        case .weekly: return self.weekly
        }
    }
}

/// Persisted roster (Application Support/ClaudeBar/accounts.json).
struct AccountsState: Sendable, Codable {
    var accounts: [Account]
    var activeAccountUuid: String?

    static let empty = AccountsState(accounts: [], activeAccountUuid: nil)
}

struct AccountUsage: Sendable, Codable {
    var session: UsageMetric?
    var weekly: UsageMetric?
    var fable: UsageMetric?
    var extraUsage: UsageMetric?
    var fetchedAt: Date

    /// A limit window rolled over after this was fetched, so its cached figures
    /// are wrong no matter how recent the fetch.
    func hasWindowResetSinceFetch(now: Date) -> Bool {
        [self.session, self.weekly, self.fable].contains { metric in
            guard let resetsAt = metric?.resetsAt else { return false }
            return resetsAt > self.fetchedAt && resetsAt <= now
        }
    }
}

/// Persisted usage cache (Caches/ClaudeBar/usage-cache-v2.json).
struct UsageCacheFile: Sendable, Codable {
    var usageByAccount: [String: AccountUsage]
    var cost: CostSnapshot?

    static let empty = UsageCacheFile(usageByAccount: [:], cost: nil)
}

/// Everything the UI needs to render one account row.
struct AccountDisplay: Sendable, Identifiable {
    let account: Account
    let usage: AccountUsage?
    let isActive: Bool
    var isRecommended: Bool
    let isStale: Bool
    /// The limits this account is held to, with the global defaults filled in.
    let limits: AccountLimits
    /// Pace and forecast. Only the UI snapshot computes these; the planner has no use for them.
    var insight: AccountInsight?

    var id: String { self.account.id }
}

/// What the usage history says about one account.
struct AccountInsight: Sendable {
    /// How fast usage moved over the last half hour.
    let currentPace: CurrentPace?
    /// How fast this account's limits fill per hour of active work.
    let typicalPace: TypicalPace?
    /// The typical pace is pooled across every account, for want of enough of this one's own.
    let isPacePooled: Bool
    /// Where usage is headed if all work went to this account; nil without a pace.
    let forecast: AccountForecast?
    /// Hours of work the remaining weekly room covers at the typical pace.
    let bankedHours: Double?
    /// Weekly usage recorded since the current weekly window opened.
    let weeklyHistory: [UsagePoint]
}

/// A global hotkey, stored in Carbon's units because `RegisterEventHotKey` takes
/// them directly; `ShortcutRecorder` converts from `NSEvent` at the boundary.
struct KeyCombo: Sendable, Codable, Equatable {
    /// Carbon modifier bits, spelled out so this file stays Foundation-only.
    /// These match HIToolbox's `cmdKey`/`shiftKey`/`optionKey`/`controlKey`.
    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000

    let keyCode: UInt32
    let modifiers: UInt32

    /// A bare key would swallow that keystroke system-wide, which is never what
    /// someone means to configure. Whether the *specific* modifiers are acceptable
    /// is left to the OS: Sequoia rejects shift/option-only combos with -9868, but
    /// 15.2 relaxed that again, so hardcoding the rule here would be wrong on one
    /// version or the other.
    var hasModifier: Bool { self.modifiers != 0 }
}

/// Why the live login moved to another account.
enum SwitchTrigger: Sendable {
    case user
    /// Auto-switching, with the condition on the previous account that caused it.
    case automatic(reason: SwitchReason)
}

/// The condition on the active account that made auto-switching move the login.
enum SwitchReason: Sendable, Equatable, CustomStringConvertible {
    case sessionAtLimit(percent: Int, limit: Int)
    case weeklyAtLimit(percent: Int, limit: Int)
    /// Usage would cross the limit before the next check.
    case sessionClimbing(percent: Int, limit: Int)
    case weeklyClimbing(percent: Int, limit: Int)

    /// Completes a sentence that starts with the account's email.
    var description: String {
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

enum BannerKind: Sendable {
    case info
    case warning
    case error
}

struct Banner: Sendable, Equatable {
    let kind: BannerKind
    let message: String
}

/// Sendable snapshot of AccountManager state handed to the main actor for rendering.
struct AccountsSnapshot: Sendable {
    let displays: [AccountDisplay]
    let banner: Banner?
    let cost: CostSnapshot?
    let updatedAt: Date?
    /// Whether the accounts together carry the expected work; nil until the
    /// history holds enough work to measure a pace.
    let fleet: FleetForecast?
    /// When the user tends to work: the configured schedule, reshaped by
    /// whatever history there is so far.
    let activity: ActivityProfile
}
