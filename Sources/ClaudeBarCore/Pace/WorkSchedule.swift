import Foundation

/// Days of the week, numbered the way `Calendar.component(.weekday, from:)` does.
public enum Weekday: Int, Sendable, Codable, CaseIterable, Comparable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    /// The week in the order the user's locale shows it, e.g. Monday first.
    public static func localeOrdered(calendar: Calendar = .current) -> [Weekday] {
        let first = calendar.firstWeekday
        return (0..<7).compactMap { Weekday(rawValue: (first - 1 + $0) % 7 + 1) }
    }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The hours someone expects to be working. Forecasts start from this and give
/// way to the rhythm the usage history actually shows as it accumulates.
public struct WorkSchedule: Sendable, Codable, Equatable {
    public var workdays: Set<Weekday>
    /// First working hour of the day, 0-23.
    public var startHour: Int
    /// Hour the working day ends, 1-24; this hour itself is not worked.
    public var endHour: Int

    public static let `default` = WorkSchedule(
        workdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
        startHour: 9,
        endHour: 18)

    public func isWorkday(_ weekday: Weekday) -> Bool {
        self.workdays.contains(weekday)
    }

    public func isWorkingHour(_ weekday: Weekday, hour: Int) -> Bool {
        self.isWorkday(weekday) && hour >= self.startHour && hour < self.endHour
    }
}
