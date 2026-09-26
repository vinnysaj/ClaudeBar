import Foundation
import Testing
@testable import ClaudeBar

@Suite("Cost totals")
struct CostSnapshotTests {
    private let calendar: Calendar
    /// 21:30 EST on November 20, 2026, when it is already 02:30 UTC on the 21st.
    private let now: Date

    init() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        self.calendar = calendar
        self.now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 21, minute: 30)))
    }

    /// The instant New York clocks read `hour`:00 on the given day of 2026.
    private func local(month: Int, day: Int, hour: Int) throws -> Date {
        try #require(self.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
    }

    private func summarize(_ hours: [HourlyUsage]) -> CostSnapshot {
        CostSnapshot(summarizing: hours, now: self.now, calendar: self.calendar)
    }

    @Test("Today runs from local midnight, not from midnight UTC")
    func todayIsTheLocalDay() throws {
        // 23:00 EST on November 19 is 04:00 UTC on the 20th.
        let lateYesterday = try HourlyUsage(
            start: self.local(month: 11, day: 19, hour: 23), cost: 0.5, tokens: 1_000, unpricedModels: [])
        // 00:00 EST on November 20 is 05:00 UTC on the 20th, the UTC day before now's.
        let firstHourToday = try HourlyUsage(
            start: self.local(month: 11, day: 20, hour: 0), cost: 2, tokens: 20_000, unpricedModels: [])

        let snapshot = self.summarize([lateYesterday, firstHourToday])

        #expect(snapshot.todayTokens == 20_000)
        #expect(snapshot.todayCostUSD == 2)
        #expect(snapshot.last30DaysTokens == 21_000)
        #expect(snapshot.last30DaysCostUSD == 2.5)
    }

    @Test("The 30-day totals start at local midnight 30 days before today")
    func thirtyDayWindowStartsAtLocalMidnight() throws {
        // 00:00 EDT on October 21 is 04:00 UTC: 30 days and an hour before today's midnight,
        // since daylight saving time ended on November 1.
        let firstHourOfWindow = try HourlyUsage(
            start: self.local(month: 10, day: 21, hour: 0), cost: 1, tokens: 1_000,
            unpricedModels: ["claude-in-window"])
        // 23:00 EDT on October 20 is 03:00 UTC on the 21st.
        let lastHourBeforeWindow = try HourlyUsage(
            start: self.local(month: 10, day: 20, hour: 23), cost: 1, tokens: 20_000,
            unpricedModels: ["claude-before-window"])

        let snapshot = self.summarize([lastHourBeforeWindow, firstHourOfWindow])

        #expect(snapshot.last30DaysTokens == 1_000)
        #expect(snapshot.unpricedModels == ["claude-in-window"])
    }

    @Test("The hourly chart keeps the hour straddling its week-old edge and lists hours oldest first")
    func hourlyChartKeepsTheHourAcrossItsEdge() throws {
        // The chart's edge is 21:30 EST on November 13, 02:30 UTC on the 14th.
        let endsBeforeEdge = try HourlyUsage(
            start: self.local(month: 11, day: 13, hour: 20), cost: 1, tokens: 1_000, unpricedModels: [])
        // 21:00 to 22:00 EST on November 13 is 02:00 to 03:00 UTC on the 14th.
        let acrossEdge = try HourlyUsage(
            start: self.local(month: 11, day: 13, hour: 21), cost: 1, tokens: 20_000, unpricedModels: [])
        let currentHour = try HourlyUsage(
            start: self.local(month: 11, day: 20, hour: 21), cost: 1, tokens: 300_000, unpricedModels: [])

        let snapshot = self.summarize([currentHour, acrossEdge, endsBeforeEdge])

        #expect(snapshot.hours == [acrossEdge, currentHour])
    }
}
