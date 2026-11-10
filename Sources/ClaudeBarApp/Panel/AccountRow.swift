import ClaudeBarCore
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
                if self.model.signIn?.accountId == display.id {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Signing in")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button("Cancel", action: self.actions.cancelSignIn)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 10))
                } else if display.account.needsRelogin {
                    Button("Sign In") { self.actions.signIn(display.id) }
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
            // Fixed-height body for the first two lines, so a refresh mid-open
            // never shifts rows below.
            let lines = display.usageLines
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
                } else if display.usage != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lines.prefix(2), id: \.metric.label) { line in
                            CompactMetricLine(line: line, stale: display.isStale)
                        }
                    }
                } else {
                    Text("No usage data yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 32, alignment: .center)

            if !display.account.needsRelogin {
                ForEach(lines.dropFirst(2), id: \.metric.label) { line in
                    CompactMetricLine(line: line, stale: display.isStale)
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
    /// Its limit is drawn as a tick on the bar; none for figures auto-switching doesn't watch.
    let line: UsageLine
    let stale: Bool

    var body: some View {
        let metric = self.line.metric
        HStack(spacing: 6) {
            Text(metric.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
                .lineLimit(1)
            if metric.isUnlimited {
                Text("Unlimited")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                let percent = metric.effectiveUsedPercent(at: Date())
                UsageProgressBar(
                    percent: percent,
                    limit: self.line.limit,
                    tintColor: UsageColors.bar(percent: percent, limit: self.line.limit))
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
    static func bar(percent: Int, limit: Int?) -> Color {
        switch UsageLevel(percent: percent, limit: limit) {
        case .over: return .red
        case .near: return .orange
        case .normal: return Color(nsColor: .controlAccentColor)
        }
    }
}
