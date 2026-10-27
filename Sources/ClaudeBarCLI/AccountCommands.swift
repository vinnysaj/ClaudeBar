import ArgumentParser
import ClaudeBarCore
import Foundation

private let accountHelp = ArgumentHelp(
    "The account: its number in `claudebar status`, its email, or enough of the email to tell it apart.",
    valueName: "account")

struct SwitchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Move Claude Code's login to another account.",
        discussion: "Running claude sessions pick up the new account within seconds.")

    @Argument(help: accountHelp)
    var account: String

    func run() async throws {
        try await Request.run(.switchAccount(selector: self.account))
    }
}

struct RemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Forget an account's stored login and usage.",
        discussion: "The Anthropic account itself is not affected. The active account can't be removed.")

    @Argument(help: accountHelp)
    var account: String

    @Flag(name: .shortAndLong, help: "Don't ask first.")
    var yes = false

    func run() async throws {
        let displays = try await Request.status().engine.snapshot?.displays ?? []
        let display = try AccountSelector.resolve(self.account, in: displays)
        guard self.yes || Terminal.confirm("Remove \(display.account.email) from ClaudeBar?") else {
            throw CleanExit.message("Kept \(display.account.email).")
        }
        // By id, so the account confirmed is the one removed.
        try await Request.run(.removeAccount(selector: display.id))
    }
}

struct RefreshCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Fetch every account's usage now.")

    func run() async throws {
        try await Request.run(.refresh)
    }
}

struct LimitsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "limits",
        abstract: "Show or set the limits one account is held to.",
        discussion: """
            An account stops taking work at either limit, and auto-switching moves the login \
            to the next account. A weekly limit below 100% keeps the rest for claude.ai. \
            Without options, shows the account's limits.
            """)

    @Argument(help: accountHelp)
    var account: String

    @Option(help: ArgumentHelp("Session percent to stop at, or `default`.", valueName: "percent"))
    var session: LimitValue?

    @Option(help: ArgumentHelp("Weekly percent to stop at, or `default`.", valueName: "percent"))
    var weekly: LimitValue?

    @Option(name: .customLong("auto-switch"), help: ArgumentHelp("Whether auto-switching may move the login onto this account.", valueName: "on|off"))
    var autoSwitch: Toggle?

    func run() async throws {
        let changes: [AccountChange] = [
            self.session.map { .sessionLimit($0.percent) },
            self.weekly.map { .weeklyLimit($0.percent) },
            self.autoSwitch.map { .allowsAutoSwitch($0.isOn) },
        ].compactMap { $0 }

        let status = try await Request.status()
        let display = try AccountSelector.resolve(self.account, in: status.engine.snapshot?.displays ?? [])
        for change in changes {
            _ = try await Request.done(.configureAccount(selector: display.id, change: change))
        }
        let current = changes.isEmpty ? display : try await self.refetch(display.id)
        let preferences = current.account.preferences
        print(current.account.email)
        print("  Session limit  \(current.limits.session)%" + (preferences.sessionLimit == nil ? " (default)" : ""))
        print("  Weekly limit   \(current.limits.weekly)%" + (preferences.weeklyLimit == nil ? " (default)" : ""))
        print("  Auto-switch    \(preferences.allowsAutoSwitch ? "may switch to it" : "never switches to it")")
    }

    private func refetch(_ accountId: String) async throws -> AccountDisplay {
        let displays = try await Request.status().engine.snapshot?.displays ?? []
        guard let display = displays.first(where: { $0.id == accountId }) else {
            throw CLIFailure("The account is gone.")
        }
        return display
    }
}

/// A percent from `AccountLimits.choices`, or `default` to follow the shared setting.
struct LimitValue: ExpressibleByArgument {
    let percent: Int?

    init?(argument: String) {
        let text = argument.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        if text.lowercased() == "default" {
            self.percent = nil
        } else if let percent = Int(text) {
            self.percent = percent
        } else {
            return nil
        }
    }
}

enum Toggle: String, ExpressibleByArgument, CaseIterable {
    case on
    case off

    var isOn: Bool { self == .on }
}
