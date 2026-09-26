import Charts
import SwiftUI

/// The hover panel for one account: usage against its limits, how fast it's
/// filling, where it's headed, and the limits themselves.
struct AccountDetailView: View {
    let accountId: String
    let model: PanelModel
    let actions: PanelActions

    var body: some View {
        if let display = self.model.display(for: self.accountId) {
            let now = Date()
            VStack(alignment: .leading, spacing: 12) {
                self.header(display)
                Divider()
                self.usageSection(display, now: now)
                self.paceSection(display)
                self.forecastSection(display, now: now)
                Divider()
                self.limitsSection(display)
            }
            .padding(PanelLayout.horizontalPadding)
        }
    }

    // MARK: - Header

    private func header(_ display: AccountDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(display.account.email)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                AccountBadges(
                    display: display,
                    showsSwitchingBadges: self.model.hasSeveralAccounts,
                    autoSwitchEnabled: self.model.usageSettings.autoSwitchEnabled)
                Spacer(minLength: 0)
            }
            if let organization = display.account.organizationName {
                Text(organization)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if display.account.needsRelogin {
                Label("Needs a fresh login: switch to it, then run claude and /login.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let usage = display.usage {
                Text("Checked \(Formatting.timeAgo(from: usage.fetchedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Usage

    @ViewBuilder
    private func usageSection(_ display: AccountDisplay, now: Date) -> some View {
        if let usage = display.usage {
            VStack(alignment: .leading, spacing: 8) {
                DetailMetricRow(label: "Session", metric: usage.session, limit: display.limits.session, now: now)
                DetailMetricRow(label: "Weekly", metric: usage.weekly, limit: display.limits.weekly, now: now)
                if let fable = usage.fable {
                    DetailMetricRow(label: fable.label, metric: fable, limit: nil, now: now)
                }
                if let extra = usage.extraUsage {
                    DetailMetricRow(label: extra.label, metric: extra, limit: nil, now: now)
                }
            }
        } else {
            Text("No usage fetched yet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pace

    private func paceSection(_ display: AccountDisplay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Pace")
            DetailLine(label: "Right now", value: Self.currentPaceText(display.insight?.currentPace))
            DetailLine(label: "Typically", value: Self.typicalPaceText(display.insight))
        }
    }

    private static func currentPaceText(_ pace: CurrentPace?) -> String {
        guard let pace, pace.sessionPerHour != nil || pace.weeklyPerHour != nil else {
            return "Not enough recent readings"
        }
        let session = max(0, pace.sessionPerHour ?? 0)
        let weekly = max(0, pace.weeklyPerHour ?? 0)
        guard session > 0 || weekly > 0 else { return "Idle for the last half hour" }
        return "\(Formatting.rate(session)) session \u{00B7} \(Formatting.rate(weekly)) weekly"
    }

    private static func typicalPaceText(_ insight: AccountInsight?) -> String {
        guard let pace = insight?.typicalPace else {
            return "Learning; needs about an hour of work"
        }
        let source = insight?.isPacePooled == true ? " (all accounts)" : ""
        return "\(Formatting.rate(pace.sessionPerActiveHour)) session \u{00B7} \(Formatting.rate(pace.weeklyPerActiveHour)) weekly per working hour\(source)"
    }

    // MARK: - Forecast

    @ViewBuilder
    private func forecastSection(_ display: AccountDisplay, now: Date) -> some View {
        if let usage = display.usage, !display.account.needsRelogin {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(text: display.isActive ? "If you keep working here" : "If you worked here")
                if let forecast = display.insight?.forecast {
                    DetailLine(
                        label: "Session",
                        value: Self.sessionOutlook(usage.session, limit: display.limits.session, forecast: forecast, now: now))
                    DetailLine(
                        label: "Weekly",
                        value: Self.weeklyOutlook(usage.weekly, limit: display.limits.weekly, forecast: forecast, now: now))
                    if let banked = display.insight?.bankedHours {
                        DetailLine(
                            label: "Banked",
                            value: "\(Formatting.workHours(banked)) of work under the weekly limit")
                    }
                    if let resetsAt = usage.weekly?.resetsAt, resetsAt > now {
                        WeeklyUsageChart(
                            recorded: display.insight?.weeklyHistory ?? [],
                            projected: forecast.weeklyProjection,
                            limit: display.limits.weekly,
                            windowStart: resetsAt.addingTimeInterval(-AutoSwitchPlanner.weeklyWindow),
                            windowEnd: resetsAt,
                            now: now)
                            .padding(.top, 4)
                    }
                } else {
                    Text("Forecasts start once ClaudeBar has seen about an hour of work.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func sessionOutlook(
        _ metric: UsageMetric?, limit: Int, forecast: AccountForecast, now: Date) -> String
    {
        if let metric, metric.effectiveUsedPercent(at: now) >= limit {
            return "At its \(limit)% limit"
        }
        if let limitAt = forecast.sessionLimitAt {
            return "Reaches \(limit)% ~\(Formatting.approximateMoment(limitAt, now: now)) (in \(Formatting.duration(limitAt.timeIntervalSince(now))))"
        }
        if let percent = forecast.sessionPercentAtReset, let resetsAt = metric?.resetsAt, resetsAt > now {
            return "~\(Int(percent.rounded()))% by its \(Formatting.moment(resetsAt, now: now)) reset"
        }
        return "No session open"
    }

    private static func weeklyOutlook(
        _ metric: UsageMetric?, limit: Int, forecast: AccountForecast, now: Date) -> String
    {
        if let metric, metric.effectiveUsedPercent(at: now) >= limit {
            return "At its \(limit)% limit"
        }
        if let limitAt = forecast.weeklyLimitAt {
            return "Reaches \(limit)% ~\(Formatting.approximateMoment(limitAt, now: now)) (in \(Formatting.duration(limitAt.timeIntervalSince(now))))"
        }
        if let percent = forecast.weeklyPercentAtReset, let resetsAt = metric?.resetsAt, resetsAt > now {
            return "~\(Int(percent.rounded()))% by its \(Formatting.moment(resetsAt, now: now)) reset"
        }
        return "Stays under its limit"
    }

    // MARK: - Limits

    private func limitsSection(_ display: AccountDisplay) -> some View {
        let preferences = display.account.preferences
        let defaults = self.model.usageSettings
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Limits")
            LimitStepper(
                title: "Session",
                value: preferences.sessionLimit,
                defaultValue: defaults.switchAtSessionPercent)
            { newValue in
                self.update(display) { $0.sessionLimit = newValue }
            }
            LimitStepper(
                title: "Weekly",
                value: preferences.weeklyLimit,
                defaultValue: defaults.switchAtWeeklyPercent)
            { newValue in
                self.update(display) { $0.weeklyLimit = newValue }
            }
            Toggle("Use for automatic switching", isOn: Binding(
                get: { preferences.allowsAutoSwitch },
                set: { isOn in self.update(display) { $0.allowsAutoSwitch = isOn } }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Text("Auto-switching moves off this account at either limit and won't move onto it near one. Whatever is left above a limit stays free for claude.ai.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func update(_ display: AccountDisplay, _ change: (inout AccountPreferences) -> Void) {
        var preferences = display.account.preferences
        change(&preferences)
        self.actions.updatePreferences(display.id, preferences)
    }
}

/// A limit that follows the global default until it's stepped away from it.
private struct LimitStepper: View {
    let title: String
    /// Nil follows the default.
    let value: Int?
    let defaultValue: Int
    let onChange: (Int?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(self.title)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Stepper(
                value: Binding(
                    get: { self.value ?? self.defaultValue },
                    // Landing back on the default follows it again, so a later
                    // change to the default carries through.
                    set: { self.onChange($0 == self.defaultValue ? nil : $0) }),
                in: AccountPreferences.limitRange,
                step: AccountPreferences.limitStep)
            {
                Text("\(self.value ?? self.defaultValue)%")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            if self.value == nil {
                Text("default")
                    .foregroundStyle(.tertiary)
            } else {
                Button("Use default") { self.onChange(nil) }
                    .buttonStyle(.hoverBackground)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }
}

/// One limit window: its bar with the limit marked, then the figures.
private struct DetailMetricRow: View {
    let label: String
    let metric: UsageMetric?
    let limit: Int?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(self.label)
                    .font(.system(size: 11))
                    .frame(width: 58, alignment: .leading)
                    .lineLimit(1)
                if let metric = self.metric, !metric.isUnlimited {
                    let percent = metric.effectiveUsedPercent(at: self.now)
                    UsageProgressBar(
                        percent: percent,
                        limit: self.limit,
                        tintColor: UsageColors.bar(percent: percent, limit: self.limit))
                    Text("\(percent)%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                } else {
                    Text(self.metric?.isUnlimited == true ? "Unlimited" : "--")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            let caption = self.caption
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 66)
            }
        }
    }

    private var caption: String {
        var parts: [String] = []
        if let limit = self.limit {
            parts.append("Limit \(limit)%")
        }
        if let spent = self.metric?.spentDescription {
            parts.append(spent)
        } else if let resetsAt = self.metric?.resetsAt {
            parts.append(Formatting.resetDescription(from: resetsAt))
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// This weekly window so far, where it's headed, and the limit.
private struct WeeklyUsageChart: View {
    let recorded: [UsagePoint]
    let projected: [UsagePoint]
    let limit: Int
    let windowStart: Date
    let windowEnd: Date
    let now: Date

    var body: some View {
        let accent = Color(nsColor: .controlAccentColor)
        Chart {
            ForEach(Array(self.recorded.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Used", point.percent),
                    series: .value("Series", "Recorded"))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            ForEach(Array(self.projected.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Used", point.percent),
                    series: .value("Series", "Projected"))
                    .foregroundStyle(accent.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            RuleMark(y: .value("Limit", self.limit))
                .foregroundStyle(Color.red.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            RuleMark(x: .value("Now", self.now))
                .foregroundStyle(Color.secondary.opacity(0.35))
        }
        .chartXScale(domain: self.windowStart...self.windowEnd)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%").font(.system(size: 8))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                    .font(.system(size: 8))
            }
        }
        .frame(height: 96)
        .accessibilityLabel("Weekly usage this window, recorded and projected, against the \(self.limit)% limit")
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// A label and its value, the label in a fixed column.
struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(self.label)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(self.value)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }
}
