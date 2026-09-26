import SwiftUI

/// How the fleet forecast reads at a glance.
struct FleetStatus {
    enum Level {
        case learning
        case covered
        /// Runs out within the horizon, but not today.
        case tight
        /// Runs out within the day, or already has.
        case short
    }

    let level: Level
    let headline: String
    let detail: String

    /// A forecast running out sooner than this is already here.
    private static let alreadyOut: TimeInterval = 15 * 60
    private static let soon: TimeInterval = 24 * 60 * 60

    init(fleet: FleetForecast?, now: Date) {
        guard let fleet else {
            self.level = .learning
            self.headline = "Learning your pace"
            self.detail = "needs about an hour of work"
            return
        }
        guard let runsOutAt = fleet.runsOutAt else {
            self.level = .covered
            self.headline = "On pace for the week"
            self.detail = "\(Formatting.workHours(fleet.bankedHours)) banked"
            return
        }
        let remaining = runsOutAt.timeIntervalSince(now)
        self.level = remaining < Self.soon ? .short : .tight
        self.headline = remaining < Self.alreadyOut
            ? "Every account is at its limits"
            : "Runs out ~\(Formatting.approximateMoment(runsOutAt, now: now))"
        self.detail = fleet.resumesAt.map { "back \(Formatting.approximateMoment($0, now: now))" } ?? ""
    }

    var color: Color {
        switch self.level {
        case .learning: return .secondary
        case .covered: return .green
        case .tight: return .orange
        case .short: return .red
        }
    }
}

/// The fleet forecast in one line: a dot colored by how it reads, the verdict, and a detail.
struct FleetStatusLine: View {
    let fleet: FleetForecast?

    var body: some View {
        let status = FleetStatus(fleet: self.fleet, now: Date())
        HStack(spacing: 7) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.headline)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(status.detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Whether the accounts together carry the work ahead, what each has left, and
/// the weekly rhythm the forecast assumes.
struct FleetPaceSection: View {
    let snapshot: AccountsSnapshot?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(text: "Pace")
                Text(Self.summary(self.snapshot?.fleet, now: self.now))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = self.snapshot, snapshot.fleet != nil {
                self.capacitySection(snapshot)
            }
            Divider()
            if let activity = self.snapshot?.activity {
                self.activitySection(activity)
            }
            Text("Forecasts move work to the next account as each one fills, the way auto-switching does, and follow your current pace for the next couple of hours before easing into your usual rhythm.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func summary(_ fleet: FleetForecast?, now: Date) -> String {
        guard let fleet else {
            return "ClaudeBar learns how fast your accounts fill from the usage it records. Forecasts start once it has seen about an hour of work."
        }
        let expected = Formatting.workHours(fleet.expectedWorkHours)
        guard let runsOutAt = fleet.runsOutAt else {
            return "At your usual pace your accounts carry the next 7 days: about \(expected) of work, every hour of it with an account under its limits. \(Formatting.workHours(fleet.bankedHours)) is banked before any weekly reset."
        }
        var sentences = [
            "At this pace every account reaches its limits around \(Formatting.approximateMoment(runsOutAt, now: now)).",
        ]
        if let resumesAt = fleet.resumesAt {
            sentences.append("Room comes back ~\(Formatting.approximateMoment(resumesAt, now: now)).")
        }
        sentences.append("Over the next 7 days you'd be about \(Formatting.workHours(fleet.shortfallHours)) of work short of the \(expected) expected.")
        return sentences.joined(separator: " ")
    }

    private func capacitySection(_ snapshot: AccountsSnapshot) -> some View {
        let largest = snapshot.displays.compactMap { $0.insight?.bankedHours }.max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Work left under weekly limits")
            ForEach(snapshot.displays) { display in
                CapacityRow(display: display, largestBankedHours: largest, now: self.now)
            }
        }
    }

    private func activitySection(_ activity: ActivityProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "When you work")
            ActivityHeatmap(profile: activity)
            Text(Self.activityCaption(activity))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func activityCaption(_ activity: ActivityProfile) -> String {
        let typicalWeek = "A typical week holds about \(Formatting.workHours(activity.weeklyActiveHours)) of active work."
        guard activity.observedHours >= 24 else {
            return "\(typicalWeek) Mostly your work hours from Settings so far; ClaudeBar reshapes this as it records your usage."
        }
        return "\(typicalWeek) Learned from \(Formatting.workHours(activity.observedHours)) of history; your work hours in Settings fill the gaps."
    }
}

/// One account's remaining weekly room, in hours of work.
private struct CapacityRow: View {
    let display: AccountDisplay
    let largestBankedHours: Double
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(self.display.account.email)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(self.figure)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: 10))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(self.barColor)
                        .frame(width: geometry.size.width * self.fraction)
                }
            }
            .frame(height: 4)
        }
    }

    private var fraction: CGFloat {
        guard self.largestBankedHours > 0, let banked = self.display.insight?.bankedHours else { return 0 }
        return CGFloat(min(1, banked / self.largestBankedHours))
    }

    private var barColor: Color {
        self.display.account.preferences.allowsAutoSwitch || self.display.isActive
            ? Color(nsColor: .controlAccentColor)
            : Color.secondary.opacity(0.5)
    }

    private var figure: String {
        if self.display.account.needsRelogin { return "needs login" }
        guard let banked = self.display.insight?.bankedHours else { return "--" }
        if banked < 0.05 {
            let resetsAt = self.display.usage?.weekly?.resetsAt
            return resetsAt.map { "full until \(Formatting.moment($0, now: self.now))" } ?? "full"
        }
        let excluded = self.display.account.preferences.allowsAutoSwitch || self.display.isActive ? "" : " (manual)"
        return "\(Formatting.workHours(banked))\(excluded)"
    }
}

/// The learned week: one row per day, one cell per hour, darker where work is likelier.
struct ActivityHeatmap: View {
    let profile: ActivityProfile

    private static let cellSize: CGFloat = 10
    private static let cellSpacing: CGFloat = 1.5
    private static let dayLabelWidth: CGFloat = 14

    var body: some View {
        let days = Weekday.localeOrdered()
        let busiest = max(self.profile.hourly.max() ?? 0, 0.01)
        let accent = Color(nsColor: .controlAccentColor)
        VStack(alignment: .leading, spacing: Self.cellSpacing) {
            ForEach(days, id: \.self) { day in
                HStack(spacing: Self.cellSpacing) {
                    Text(Self.dayInitial(day))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.dayLabelWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(accent.opacity(0.07 + 0.93 * self.profile.share(day, hour: hour) / busiest))
                            .frame(width: Self.cellSize, height: Self.cellSize)
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(Self.hourLabel(hour))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(width: 6 * (Self.cellSize + Self.cellSpacing), alignment: .leading)
                }
            }
            .padding(.leading, Self.dayLabelWidth + Self.cellSpacing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typical weekly activity by day and hour")
    }

    private static func dayInitial(_ day: Weekday) -> String {
        Calendar.current.veryShortWeekdaySymbols[day.rawValue - 1]
    }

    private static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        default: return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
        }
    }
}
