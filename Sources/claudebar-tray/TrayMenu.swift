import ClaudeBarCore
import Foundation

/// What a menu item does when chosen.
enum TrayAction: Sendable, Equatable {
    case switchTo(accountId: String)
    case signIn(accountId: String?)
    case remove(accountId: String, email: String)
    case allowAutoSwitch(accountId: String, Bool)
    case refresh
    case autoSwitch(Bool)
    case startAtLogin(Bool)
    case openSignInPage
    case copySignInLink
    case pasteSignInCode
    case cancelSignIn
    case quit
}

/// One item of the tray's menu. Ubuntu's top bar draws AppIndicator menus
/// itself, so items are text, checkboxes and submenus only.
struct MenuEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case item
        case check(Bool)
        case separator
        case submenu([MenuEntry])
    }

    var label: String
    var kind: Kind
    var action: TrayAction?

    static let separator = MenuEntry(label: "", kind: .separator, action: nil)

    static func text(_ label: String) -> MenuEntry {
        MenuEntry(label: label, kind: .item, action: nil)
    }

    static func item(_ label: String, _ action: TrayAction) -> MenuEntry {
        MenuEntry(label: label, kind: .item, action: action)
    }

    static func check(_ label: String, _ isOn: Bool, _ action: TrayAction) -> MenuEntry {
        MenuEntry(label: label, kind: .check(isOn), action: action)
    }

    /// Whether `other` can be shown by relabeling this one's items, without
    /// building the menu over, which would close it under the pointer.
    func hasSameShape(as other: MenuEntry) -> Bool {
        guard self.action == other.action else { return false }
        switch (self.kind, other.kind) {
        case (.item, .item), (.separator, .separator):
            return true
        case (.check(let isOn), .check(let otherIsOn)):
            return isOn == otherIsOn
        case (.submenu(let children), .submenu(let otherChildren)):
            return children.count == otherChildren.count
                && zip(children, otherChildren).allSatisfy { $0.hasSameShape(as: $1) }
        default:
            return false
        }
    }
}

/// The sign-in the tray started, which it hands the page and codes for.
struct TraySignIn {
    var email: String?
    var pages: SignInPages?
    var isLinkCopied = false
}

/// The panel's content, as the menu a tray icon can have.
enum TrayMenu {
    /// `problem` says why there's no status, when there isn't one.
    static func entries(
        status: ControlStatus?, problem: String?, signIn: TraySignIn?, startsAtLogin: Bool, now: Date) -> [MenuEntry]
    {
        guard let status else {
            return (problem.map { [.text($0)] } ?? [.text("Connecting to ClaudeBar...")]) + [
                .separator,
                .check("Start at Login", startsAtLogin, .startAtLogin(!startsAtLogin)),
                .item("Quit", .quit),
            ]
        }
        let engine = status.engine
        var entries: [MenuEntry] = []

        var header = "Claude"
        if let updatedAt = engine.snapshot?.updatedAt {
            header += " · updated \(Formatting.timeAgo(from: updatedAt))"
        }
        if engine.isRefreshing {
            header += " · refreshing"
        }
        entries.append(.text(header))
        if let banner = engine.snapshot?.banner {
            entries.append(.text(banner.message))
        }
        entries.append(.separator)

        let displays = engine.snapshot?.displays ?? []
        if engine.snapshot == nil {
            entries.append(.text("Loading..."))
        } else if displays.isEmpty {
            entries.append(.text("No accounts yet: add one below, or run claude and /login"))
        }
        for display in displays {
            entries.append(self.account(display, among: displays.count, settings: engine.settings, now: now))
        }

        if let snapshot = engine.snapshot, !displays.isEmpty {
            entries.append(.separator)
            let fleet = FleetStatus(fleet: snapshot.fleet, now: now)
            entries.append(.text(([fleet.headline] + (fleet.detail.isEmpty ? [] : [fleet.detail])).joined(separator: " · ")))
            if let overBudget = fleet.overBudget {
                entries.append(.text(overBudget))
            }
            if let cost = snapshot.cost, cost.todayTokens > 0 || cost.last30DaysTokens > 0 {
                entries.append(.text(
                    "Today \(Formatting.formatCost(cost.todayCostUSD)) · 30 days \(Formatting.formatCost(cost.last30DaysCostUSD))"))
            }
        }

        entries.append(.separator)
        entries += self.signInEntries(own: signIn, running: engine.signIn)
        entries.append(.item("Refresh Now", .refresh))
        entries.append(.check(
            "Switch Accounts Automatically", engine.settings.autoSwitchEnabled,
            .autoSwitch(!engine.settings.autoSwitchEnabled)))
        entries.append(.check("Start at Login", startsAtLogin, .startAtLogin(!startsAtLogin)))
        entries.append(.separator)
        entries.append(.item("Quit", .quit))
        return entries
    }

    private static func account(_ display: AccountDisplay, among count: Int, settings: UsageSettings, now: Date) -> MenuEntry {
        let account = display.account
        var label = (display.isActive ? "● " : "○ ") + account.email
        if account.needsRelogin {
            label += "  ·  signed out"
        } else if let usage = display.usage {
            let session = usage.session?.effectiveUsedPercent(at: now) ?? 0
            let weekly = usage.weekly?.effectiveUsedPercent(at: now) ?? 0
            label += "  ·  \(session)% session, \(weekly)% weekly"
        }
        if count > 1, !display.isActive, display.isRecommended {
            label += "  ·  next"
        }

        var details: [MenuEntry] = []
        if let usage = display.usage, !account.needsRelogin {
            let metrics: [(UsageMetric?, String, Int?)] = [
                (usage.session, "Session", display.limits.session),
                (usage.weekly, "Weekly", display.limits.weekly),
                (usage.fable, usage.fable?.label ?? "", nil),
                (usage.extraUsage, usage.extraUsage?.label ?? "", nil),
            ]
            for case let (metric?, name, limit) in metrics {
                details.append(.text(self.metric(metric, name: name, limit: limit, now: now)))
            }
            if display.isStale {
                details.append(.text("Last fetched \(Formatting.timeAgo(from: usage.fetchedAt))"))
            }
            if display.isActive, let outlook = ActiveOutlook(display: display, now: now) {
                details.append(.text(outlook.text))
            }
            details.append(.separator)
        }
        if account.needsRelogin {
            details.append(.item("Sign In", .signIn(accountId: display.id)))
        } else if !display.isActive {
            details.append(.item("Switch to This Account", .switchTo(accountId: display.id)))
        }
        let allowsAutoSwitch = account.preferences.allowsAutoSwitch
        details.append(.check(
            "Auto-Switching May Use It", allowsAutoSwitch, .allowAutoSwitch(accountId: display.id, !allowsAutoSwitch)))
        if !display.isActive {
            details.append(.item("Remove...", .remove(accountId: display.id, email: account.email)))
        }
        return MenuEntry(label: label, kind: .submenu(details), action: nil)
    }

    private static func metric(_ metric: UsageMetric, name: String, limit: Int?, now: Date) -> String {
        if metric.isUnlimited { return "\(name): unlimited" }
        var parts = ["\(name) \(metric.effectiveUsedPercent(at: now))%"]
        if let limit, limit < 100 {
            parts.append("limit \(limit)%")
        }
        if let spent = metric.spentDescription {
            parts.append(spent)
        } else if let resetsAt = metric.resetsAt {
            parts.append(Formatting.resetDescription(from: resetsAt))
        }
        return parts.joined(separator: " · ")
    }

    private static func signInEntries(own: TraySignIn?, running: SignInState?) -> [MenuEntry] {
        if let own {
            var entries: [MenuEntry] = [.text("Signing in to \(own.email ?? "a new account")...")]
            if own.pages != nil {
                if own.isLinkCopied {
                    entries.append(.text("Sign-in link copied: paste it into any browser"))
                }
                entries.append(.item("Open Sign-in Page", .openSignInPage))
                entries.append(.item(own.isLinkCopied ? "Copy Link Again" : "Copy Sign-in Link", .copySignInLink))
                entries.append(.item("Paste Code from Clipboard", .pasteSignInCode))
            }
            entries.append(.item("Cancel Sign-in", .cancelSignIn))
            return entries
        }
        if let running {
            // Started by claudebar, which hands the page on itself.
            return [.text("Signing in to \(running.email ?? "a new account") with claudebar...")]
        }
        return [.item("Add Account", .signIn(accountId: nil))]
    }
}
