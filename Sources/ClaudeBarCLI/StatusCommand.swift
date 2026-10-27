import ArgumentParser
import ClaudeBarCore
import Foundation

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show every account's usage, limits and pace.")

    @Flag(help: "Print the full status as JSON.")
    var json = false

    func run() async throws {
        let status = try await Request.status()
        if self.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(status), as: UTF8.self))
        } else {
            print(StatusText(status: status, now: Date()).render())
        }
    }
}

/// `claudebar status` as text: the panel's content, one account after another.
struct StatusText {
    let status: ControlStatus
    let now: Date

    private static let barWidth = 20

    func render() -> String {
        var lines = [self.header]
        let engine = self.status.engine
        if let banner = engine.snapshot?.banner {
            lines.append(Self.style(for: banner.kind)(banner.message))
        }
        guard let snapshot = engine.snapshot else {
            lines.append("Loading...")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        if snapshot.displays.isEmpty {
            lines.append("No accounts yet. Add one with `claudebar login`, or run claude and /login.")
        }
        let showsSwitchingTags = snapshot.displays.count > 1
        for (index, display) in snapshot.displays.enumerated() {
            lines += self.account(display, number: index + 1, showsSwitchingTags: showsSwitchingTags)
        }
        if let signIn = engine.signIn {
            lines.append("")
            lines.append(Style.yellow("Signing in to \(signIn.email ?? "a new account")..."))
        }
        lines.append("")
        lines += self.pace(snapshot)
        lines += self.cost(snapshot.cost, scan: engine.scanProgress)
        return lines.joined(separator: "\n")
    }

    private var header: String {
        var parts = [Style.bold("ClaudeBar \(self.status.version)")]
        if let updatedAt = self.status.engine.snapshot?.updatedAt {
            parts.append("updated \(Formatting.timeAgo(from: updatedAt))")
        }
        if self.status.engine.isRefreshing {
            parts.append("refreshing")
        }
        return parts.joined(separator: " · ")
    }

    private func account(_ display: AccountDisplay, number: Int, showsSwitchingTags: Bool) -> [String] {
        var tags: [String] = []
        if display.isActive {
            tags.append(Style.green("active"))
            if showsSwitchingTags, self.status.engine.settings.autoSwitchEnabled {
                tags.append(Style.green("auto"))
            }
        } else if showsSwitchingTags, display.isRecommended {
            tags.append(Style.green("next"))
        }
        if showsSwitchingTags, !display.account.preferences.allowsAutoSwitch {
            tags.append(Style.dim("auto-switch off"))
        }
        let email = display.isActive ? Style.bold(display.account.email) : display.account.email
        var lines = [(["\(number)  \(email)"] + tags).joined(separator: "  ")]

        if display.account.needsRelogin {
            lines.append("   " + Style.yellow("Signed out. Sign it back in with `claudebar login \(number)`."))
            return lines
        }
        guard let usage = display.usage else {
            lines.append("   " + Style.dim("No usage data yet"))
            return lines
        }
        lines.append(self.metric(usage.session, label: "Session", limit: display.limits.session, stale: display.isStale))
        lines.append(self.metric(usage.weekly, label: "Weekly", limit: display.limits.weekly, stale: display.isStale))
        if let fable = usage.fable {
            lines.append(self.metric(fable, label: fable.label, limit: nil, stale: display.isStale))
        }
        if let extra = usage.extraUsage {
            lines.append(self.metric(extra, label: extra.label, limit: nil, stale: display.isStale))
        }
        if display.isActive, let outlook = ActiveOutlook(display: display, now: self.now) {
            lines.append("   " + (outlook.isNear ? Style.yellow(outlook.text) : Style.dim(outlook.text)))
        }
        return lines
    }

    private func metric(_ metric: UsageMetric?, label: String, limit: Int?, stale: Bool) -> String {
        let name = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        guard let metric else { return "   \(name)" + Style.dim("--") }
        if metric.isUnlimited { return "   \(name)Unlimited" }
        let percent = metric.effectiveUsedPercent(at: self.now)
        let filled = min(Self.barWidth, max(0, Int((Double(percent) / 100 * Double(Self.barWidth)).rounded())))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: Self.barWidth - filled)
        let colored: (String) -> String = switch UsageLevel(percent: percent, limit: limit) {
        case .over: Style.red.callAsFunction
        case .near: Style.yellow.callAsFunction
        case .normal: { $0 }
        }
        let figure = "\(percent)%".leftPadded(to: 4)
        var parts = ["   \(name)\(colored(figure))  \(stale ? Style.dim(bar) : colored(bar))"]
        if let limit, limit < 100 {
            parts.append(Style.dim("limit \(limit)%"))
        }
        if let spent = metric.spentDescription {
            parts.append(Style.dim(spent))
        } else if let resetsAt = metric.resetsAt {
            parts.append(Style.dim(Formatting.resetDescription(from: resetsAt)))
        }
        return parts.joined(separator: "  ")
    }

    private func pace(_ snapshot: AccountsSnapshot) -> [String] {
        guard !snapshot.displays.isEmpty else { return [] }
        let fleet = FleetStatus(fleet: snapshot.fleet, now: self.now)
        let color: Style? = switch fleet.level {
        case .learning: .dim
        case .covered: .green
        case .tight: .yellow
        case .short: .red
        }
        let headline = color.map { $0(fleet.headline) } ?? fleet.headline
        var lines = ["Pace   " + ([headline] + (fleet.detail.isEmpty ? [] : [fleet.detail])).joined(separator: " · ")]
        if let overBudget = fleet.overBudget {
            lines.append("       " + (color.map { $0(overBudget) } ?? overBudget))
        }
        return lines
    }

    private func cost(_ cost: CostSnapshot?, scan: ScanProgress?) -> [String] {
        if let cost, cost.todayTokens > 0 || cost.last30DaysTokens > 0 {
            var lines = [
                "Cost   today \(Formatting.formatCost(cost.todayCostUSD)) (\(Formatting.formatTokens(cost.todayTokens)) tokens)"
                    + " · last 30 days \(Formatting.formatCost(cost.last30DaysCostUSD)) (\(Formatting.formatTokens(cost.last30DaysTokens)) tokens)",
            ]
            if !cost.unpricedModels.isEmpty {
                lines.append("       " + Style.yellow("Totals exclude \(cost.unpricedModels.joined(separator: ", ")): no published rates yet"))
            }
            return lines
        }
        if let scan, scan.totalFiles > 0 {
            return ["Cost   scanning logs \(scan.scannedFiles)/\(scan.totalFiles)"]
        }
        return []
    }

    private static func style(for kind: BannerKind) -> Style {
        switch kind {
        case .info: return .dim
        case .warning: return .yellow
        case .error: return .red
        }
    }
}

extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: " ", count: max(0, length - self.count)) + self
    }
}
