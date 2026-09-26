import SwiftUI

/// One account in the panel. Hovering it opens `AccountDetailView` beside the panel.
struct AccountRow: View {
    let accountId: String
    let showsDivider: Bool
    let model: PanelModel
    let actions: PanelActions

    @State private var isHovering = false

    var body: some View {
        if let display = self.model.display(for: self.accountId) {
            VStack(alignment: .leading, spacing: 0) {
                if self.showsDivider {
                    Divider().padding(.horizontal, PanelLayout.horizontalPadding)
                }
                self.content(display)
                    .padding(.vertical, 5)
                    .padding(.horizontal, PanelLayout.horizontalPadding)
                    .rowHighlight(self.isHovering)
                    .contentShape(Rectangle())
                    .onHover { self.isHovering = $0 }
            }
        }
    }

    private func content(_ display: AccountDisplay) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(display.account.email)
                    .font(.system(size: 12, weight: display.isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                AccountBadges(
                    display: display,
                    showsSwitchingBadges: self.model.hasSeveralAccounts,
                    autoSwitchEnabled: self.model.usageSettings.autoSwitchEnabled)
                Spacer()
                if !display.isActive && self.isHovering {
                    Button {
                        self.actions.removeAccount(display.id, display.account.email)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.hoverBackgroundIcon)
                    .help("Remove account")
                }
                if display.account.needsRelogin {
                    Button("Sign In") { self.actions.signIn(display.account.email) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        .disabled(self.model.signIn != nil)
                        .help("Sign in without touching Claude Code's current login")
                } else if !display.isActive {
                    Button("Switch") { self.actions.switchAccount(display.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 10))
                }
                DisclosureChevron()
            }
            // Fixed-height body so a refresh mid-open never shifts rows below.
            Group {
                if display.account.needsRelogin {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("Signed out")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if let usage = display.usage {
                    VStack(alignment: .leading, spacing: 4) {
                        CompactMetricLine(
                            metric: usage.session, fallbackLabel: "Session",
                            limit: display.limits.session, stale: display.isStale)
                        CompactMetricLine(
                            metric: usage.weekly, fallbackLabel: "Weekly",
                            limit: display.limits.weekly, stale: display.isStale)
                    }
                } else {
                    Text("No usage data yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 32, alignment: .center)

            if let usage = display.usage, !display.account.needsRelogin {
                if let fable = usage.fable {
                    CompactMetricLine(metric: fable, fallbackLabel: fable.label, limit: nil, stale: display.isStale)
                }
                if let extra = usage.extraUsage {
                    CompactMetricLine(metric: extra, fallbackLabel: extra.label, limit: nil, stale: display.isStale)
                }
            }
            if display.isActive, let outlook = ActiveOutlook(display: display, now: Date()) {
                Label(outlook.text, systemImage: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(outlook.isNear ? .orange : .secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// The nearest limit the active account is forecast to reach before its window
/// resets, in a line short enough for the row.
private struct ActiveOutlook {
    /// Under an hour away.
    let isNear: Bool
    let text: String

    init?(display: AccountDisplay, now: Date) {
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

struct AccountBadges: View {
    let display: AccountDisplay
    let showsSwitchingBadges: Bool
    let autoSwitchEnabled: Bool

    var body: some View {
        if self.display.isActive {
            BadgeView(text: "Active", color: Color(nsColor: .controlAccentColor))
            if self.autoSwitchEnabled && self.showsSwitchingBadges {
                BadgeView(text: "Auto", color: .green)
                    .help("Switches to the \"Next\" account before this one reaches either of its limits")
            }
        } else if self.showsSwitchingBadges && self.display.isRecommended {
            BadgeView(text: "Next", color: .green)
        }
    }
}

struct BadgeView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(self.text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(self.color.opacity(0.18))
            .foregroundStyle(self.color)
            .clipShape(Capsule())
    }
}

struct CompactMetricLine: View {
    let metric: UsageMetric?
    let fallbackLabel: String
    /// Drawn as a tick on the bar; nil for windows auto-switching doesn't watch.
    let limit: Int?
    let stale: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(self.metric?.label ?? self.fallbackLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
                .lineLimit(1)
            if let metric, metric.isUnlimited {
                Text("Unlimited")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let metric {
                let percent = metric.effectiveUsedPercent(at: Date())
                UsageProgressBar(
                    percent: percent,
                    limit: self.limit,
                    tintColor: UsageColors.bar(percent: percent, limit: self.limit))
                    .frame(height: 5)
                    .opacity(self.stale ? 0.5 : 1)
                Text("\(percent)%")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
                Text(self.resetText(metric))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 110, alignment: .trailing)
                    .lineLimit(1)
            } else {
                UsageProgressBar(percent: 0, limit: nil, tintColor: .clear)
                    .frame(height: 5)
                Text("--")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, alignment: .trailing)
                Text("")
                    .frame(width: 110)
            }
        }
    }

    private func resetText(_ metric: UsageMetric) -> String {
        if let spent = metric.spentDescription { return spent }
        guard let resetsAt = metric.resetsAt else { return "" }
        return Formatting.resetDescription(from: resetsAt)
    }
}

struct UsageProgressBar: View {
    let percent: Int
    /// Where the account stops taking work, marked with a tick. A limit of 100 is the bar's end.
    var limit: Int?
    var tintColor: Color = Color(nsColor: .controlAccentColor)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(self.tintColor)
                    .frame(width: max(0, geometry.size.width * CGFloat(min(self.percent, 100)) / 100))
                if let limit = self.limit, limit < 100 {
                    Capsule()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 1.5, height: geometry.size.height + 4)
                        .offset(x: geometry.size.width * CGFloat(limit) / 100 - 0.75)
                }
            }
        }
        .frame(height: 6)
    }
}

enum UsageColors {
    /// Against a limit: red once there, orange within reach of it. Without one,
    /// by how full the window is.
    static func bar(percent: Int, limit: Int?) -> Color {
        if let limit {
            if percent >= limit { return .red }
            if percent >= limit - 15 { return .orange }
            return Color(nsColor: .controlAccentColor)
        }
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return Color(nsColor: .controlAccentColor)
    }
}
