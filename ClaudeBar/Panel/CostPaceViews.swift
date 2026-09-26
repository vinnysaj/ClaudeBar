import Charts
import SwiftUI

/// Costs from the local logs and the fleet's pace at a glance. Hovering it opens
/// `CostPaceDetailView`.
struct CostPaceRow: View {
    let model: PanelModel

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, PanelLayout.horizontalPadding)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Cost & Pace")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    DisclosureChevron()
                }
                if let snapshot = self.model.snapshot, !snapshot.displays.isEmpty {
                    FleetStatusLine(fleet: snapshot.fleet)
                }
                self.costLines
            }
            .padding(.horizontal, PanelLayout.horizontalPadding)
            .padding(.vertical, 6)
            .rowHighlight(self.isHovering)
            .contentShape(Rectangle())
            .onHover { self.isHovering = $0 }
        }
    }

    @ViewBuilder
    private var costLines: some View {
        if let cost = self.model.snapshot?.cost, cost.todayTokens > 0 || cost.last30DaysTokens > 0 {
            Text("Today: \(Formatting.formatCost(cost.todayCostUSD)) \u{00B7} \(Formatting.formatTokens(cost.todayTokens)) tokens")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Last 30 days: \(Formatting.formatCost(cost.last30DaysCostUSD)) \u{00B7} \(Formatting.formatTokens(cost.last30DaysTokens)) tokens")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !cost.unpricedModels.isEmpty {
                Text("Totals exclude \(cost.unpricedModels.joined(separator: ", ")) \u{2014} no published rates yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let progress = self.model.scanProgress, !progress.isComplete {
            HStack(spacing: 6) {
                Spacer()
                Text("Scanning logs...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if progress.totalFiles > 0 {
                    Text("\(progress.scannedFiles)/\(progress.totalFiles)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if progress.totalFiles > 0 {
                ScanProgressBar(fraction: progress.fraction)
            }
        }
    }
}

/// The hover panel for costs and pace: where the tokens went hour by hour over
/// the last week, then whether the accounts carry the work ahead.
struct CostPaceDetailView: View {
    let model: PanelModel

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 12) {
            Text("Cost & Pace")
                .font(.system(size: 13, weight: .semibold))
            self.tokensSection(now: now)
            Divider()
            FleetPaceSection(snapshot: self.model.snapshot, now: now)
        }
        .padding(PanelLayout.horizontalPadding)
    }

    private func tokensSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Tokens by hour")
            if let hours = self.model.snapshot?.cost?.hours, hours.contains(where: { $0.tokens > 0 }) {
                TokenUsageChart(hours: hours, now: now)
                Text(Self.weekTotal(hours, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text(self.model.scanProgress?.isComplete == false
                    ? "Scanning logs..."
                    : "No Claude Code usage logged in the last 7 days.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func weekTotal(_ hours: [HourlyUsage], now: Date) -> String {
        let weekStart = now.addingTimeInterval(-CostSnapshot.hourlyWindow)
        let week = hours.filter { $0.end > weekStart }
        let cost = week.reduce(0) { $0 + $1.cost }
        let tokens = week.reduce(0) { $0 + $1.tokens }
        return "Last 7 days: \(Formatting.formatCost(cost)) \u{00B7} \(Formatting.formatTokens(tokens)) tokens"
    }
}

/// Tokens logged each hour over the last week, so big sessions stand out as
/// spikes. Hovering an hour reads out its figures above the chart.
private struct TokenUsageChart: View {
    let hours: [HourlyUsage]
    let now: Date

    @State private var hoveredHourStart: Date?

    var body: some View {
        let accent = Color(nsColor: .controlAccentColor)
        let domainStart = self.now.addingTimeInterval(-CostSnapshot.hourlyWindow)
        VStack(alignment: .leading, spacing: 4) {
            Text(self.readout)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Chart {
                ForEach(self.hours, id: \.start) { hour in
                    BarMark(
                        x: .value("Hour", hour.start, unit: .hour),
                        y: .value("Tokens", hour.tokens))
                        .foregroundStyle(hour.start == self.hoveredHourStart ? accent : accent.opacity(0.65))
                }
                if let hoveredHourStart = self.hoveredHourStart {
                    RuleMark(x: .value("Hour", hoveredHourStart, unit: .hour))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                }
            }
            .chartXScale(domain: domainStart...self.now)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(Formatting.formatTokens(tokens)).font(.system(size: 8))
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
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                self.hoveredHourStart = Self.hourStart(
                                    at: location, proxy: proxy, geometry: geometry, domain: domainStart...self.now)
                            case .ended:
                                self.hoveredHourStart = nil
                            }
                        }
                }
            }
            .frame(height: 90)
            .accessibilityLabel("Tokens logged each hour over the last 7 days")
        }
    }

    /// The hovered hour's figures, or the busiest hour's while nothing is hovered.
    private var readout: String {
        if let hoveredHourStart = self.hoveredHourStart {
            let label = Formatting.pastHour(hoveredHourStart, now: self.now)
            guard let hour = self.hours.first(where: { $0.start == hoveredHourStart }), hour.tokens > 0 else {
                return "\(label): nothing logged"
            }
            return "\(label): \(Self.figures(hour))"
        }
        guard let busiest = self.hours.max(by: { $0.tokens < $1.tokens }) else { return "" }
        return "Busiest hour: \(Formatting.pastHour(busiest.start, now: self.now)), \(Self.figures(busiest))"
    }

    private static func figures(_ hour: HourlyUsage) -> String {
        "\(Formatting.formatTokens(hour.tokens)) tokens \u{00B7} \(Formatting.formatCost(hour.cost))"
    }

    /// The start of the clock hour under `location`, or nil outside the plot.
    private static func hourStart(
        at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, domain: ClosedRange<Date>) -> Date?
    {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        guard let date: Date = proxy.value(atX: location.x - origin.x), domain.contains(date) else { return nil }
        return Calendar.current.dateInterval(of: .hour, for: date)?.start
    }
}

struct ScanProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: max(0, geometry.size.width * CGFloat(min(self.fraction, 1))))
            }
        }
        .frame(height: 3)
    }
}
