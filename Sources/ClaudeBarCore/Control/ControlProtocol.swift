import Foundation

// The CLI and the Linux tray drive the running ClaudeBar, the Mac app or the
// Linux daemon, over a Unix socket in its support directory. Each side sends one
// JSON value per line. A connection carries one request and its replies, except
// that a sign-in also takes `signInCode` requests on the same connection.

/// What a client asks of the running ClaudeBar.
public enum ControlRequest: Sendable, Codable {
    /// Replies `status` once.
    case status
    /// Replies `status` now and after every change, until the client hangs up.
    case watch
    /// Fetches every account's usage now. Replies `done`.
    case refresh
    case switchAccount(selector: String)
    case removeAccount(selector: String)
    case configureAccount(selector: String, change: AccountChange)
    case configure(SettingsChange)
    /// Signs an account in: the one `selector` picks, or a new one, pre-filled
    /// with `selector` when that's an email. Replies `signInStarted`, then
    /// `signInPages` once there's a page to open, then `done` or `failed`. The
    /// client sends `signInCode` meanwhile for a page that ends on a code;
    /// hanging up cancels the sign-in.
    case signIn(selector: String?)
    case signInCode(String)
    /// Updates ClaudeBar: on the Mac by opening the app's updater, on Linux by
    /// installing the latest release and restarting. Replies `progress` along
    /// the way, then `done` or `failed`.
    case update
}

public enum ControlReply: Sendable, Codable {
    case status(ControlStatus)
    case done(String)
    case failed(String)
    case progress(String)
    /// The sign-in has started, for `email` when known.
    case signInStarted(email: String?)
    case signInPages(SignInPages)
    /// The code went to claude, which signs the account in if it's right.
    case codeAccepted
    case codeRejected(String)
}

/// What `status` and `watch` report.
public struct ControlStatus: Sendable, Codable {
    public let engine: EngineState
    public let version: String
    public let build: Int
    /// Whether ClaudeBar installs updates by itself. Nil on the Mac, where the
    /// app's updater has its own setting.
    public let autoUpdate: Bool?
}

/// A change to one account's preferences.
public enum AccountChange: Sendable, Codable {
    /// A percent from `AccountLimits.choices`, or nil to follow the default.
    case sessionLimit(Int?)
    case weeklyLimit(Int?)
    case allowsAutoSwitch(Bool)

    public func applied(to preferences: AccountPreferences) throws -> AccountPreferences {
        var preferences = preferences
        switch self {
        case .sessionLimit(let percent):
            try Self.check(percent, allowed: AccountLimits.choices)
            preferences.sessionLimit = percent
        case .weeklyLimit(let percent):
            try Self.check(percent, allowed: AccountLimits.choices)
            preferences.weeklyLimit = percent
        case .allowsAutoSwitch(let allows):
            preferences.allowsAutoSwitch = allows
        }
        return preferences
    }

    private static func check(_ percent: Int?, allowed: [Int]) throws {
        guard let percent, !allowed.contains(percent) else { return }
        throw ControlError.invalidValue("A limit must be one of \(SettingsChange.list(allowed))%.")
    }
}

/// A change to the settings every account shares.
public enum SettingsChange: Sendable, Codable {
    case autoSwitch(Bool)
    case sessionLimit(Int)
    case weeklyLimit(Int)
    case refreshInterval(TimeInterval)
    case workdays(Set<Weekday>)
    /// The working day, from `start` up to `end`, in hours 0-24.
    case workHours(start: Int, end: Int)
    /// Linux only: whether the daemon installs updates by itself.
    case autoUpdate(Bool)

    /// The settings with this change made, held to the same choices the Mac's
    /// Settings window offers. Throws for `autoUpdate`, which isn't one of them.
    public func applied(to settings: UsageSettings) throws -> UsageSettings {
        var settings = settings
        switch self {
        case .autoSwitch(let isOn):
            settings.autoSwitchEnabled = isOn
        case .sessionLimit(let percent):
            try Self.check(percent, allowed: UsageSettings.switchPercentChoices, what: "The default session limit")
            settings.switchAtSessionPercent = percent
        case .weeklyLimit(let percent):
            try Self.check(percent, allowed: UsageSettings.weeklyPercentChoices, what: "The default weekly limit")
            settings.switchAtWeeklyPercent = percent
        case .refreshInterval(let interval):
            guard UsageSettings.refreshIntervalChoices.contains(interval) else {
                let minutes = UsageSettings.refreshIntervalChoices.map { Int($0 / 60) }
                throw ControlError.invalidValue("The refresh interval must be one of \(Self.list(minutes)) minutes.")
            }
            settings.refreshInterval = interval
        case .workdays(let days):
            settings.workSchedule.workdays = days
        case .workHours(let start, let end):
            guard (0...23).contains(start), (1...24).contains(end), start < end else {
                throw ControlError.invalidValue("Work hours run from a start hour 0-23 to a later end hour 1-24.")
            }
            settings.workSchedule.startHour = start
            settings.workSchedule.endHour = end
        case .autoUpdate:
            throw ControlError.invalidValue("Automatic updates aren't a usage setting.")
        }
        return settings
    }

    private static func check(_ percent: Int, allowed: [Int], what: String) throws {
        guard !allowed.contains(percent) else { return }
        throw ControlError.invalidValue("\(what) must be one of \(self.list(allowed))%.")
    }

    /// "70, 75, 80 or 85"
    public static func list(_ values: [Int]) -> String {
        let words = values.map(String.init)
        guard let last = words.last, words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " or " + last
    }
}

public enum ControlError: Error, CustomStringConvertible {
    /// Nothing is listening on the socket.
    case notRunning
    case invalidValue(String)
    case unexpectedReply
    /// The other side hung up before replying.
    case disconnected

    public var description: String {
        switch self {
        case .notRunning:
            #if os(macOS)
            return "ClaudeBar isn't running. Open it, then try again."
            #else
            return "ClaudeBar isn't running. Start it with `systemctl --user start claudebar`, or set it up with `claudebar service install`."
            #endif
        case .invalidValue(let reason):
            return reason
        case .unexpectedReply:
            return "ClaudeBar sent a reply this claudebar doesn't understand. Update both to the same version."
        case .disconnected:
            return "ClaudeBar closed the connection before replying."
        }
    }
}
