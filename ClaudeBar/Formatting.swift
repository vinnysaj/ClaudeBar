import Foundation

enum Formatting {
    static func timeAgo(from date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "<1m ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.0fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func resetDescription(from date: Date) -> String {
        let now = Date()
        guard date > now else { return "Just reset" }
        return "Resets \(self.moment(date, now: now))"
    }

    /// A moment ahead, at the precision a reset or forecast deserves: "5pm",
    /// "tomorrow 9:30am", "Thu 3pm", or just "Oct 3" beyond a week.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = calendar.component(.minute, from: date) == 0 ? "ha" : "h:mma"
        timeFormatter.amSymbol = "am"
        timeFormatter.pmSymbol = "pm"
        let time = timeFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "tomorrow \(time)"
        }
        if let weekAway = calendar.date(byAdding: .day, value: 7, to: now), date < weekAway {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE"
            return "\(dayFormatter.string(from: date)) \(time)"
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        return dateFormatter.string(from: date)
    }

    /// A forecast moment rounded to the quarter hour; forecasts are not minute-precise.
    static func approximateMoment(_ date: Date, now: Date = Date()) -> String {
        let quarterHour: TimeInterval = 15 * 60
        let rounded = Date(
            timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / quarterHour).rounded() * quarterHour)
        return self.moment(rounded, now: now)
    }

    /// A span of time: "45m", "3h 20m", "2d 5h". Anything under a minute reads "<1m".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        let days = hours / 24
        let remainder = hours % 24
        return remainder == 0 ? "\(days)d" : "\(days)d \(remainder)h"
    }

    /// Hours of work, rounded to what a forecast can honestly claim: "40m", "4.5h", "38h".
    static func workHours(_ hours: Double) -> String {
        if hours < 1 { return "\(max(1, Int((hours * 60).rounded())))m" }
        if hours < 10 { return String(format: "%.1fh", hours) }
        return "\(Int(hours.rounded()))h"
    }

    /// Percentage points per hour: "18%/h", "2.4%/h".
    static func rate(_ pointsPerHour: Double) -> String {
        String(format: abs(pointsPerHour) >= 10 ? "%.0f%%/h" : "%.1f%%/h", pointsPerHour)
    }

    static func formatCost(_ cost: Double) -> String {
        if cost >= 10_000 {
            return String(format: "$%.0f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}
