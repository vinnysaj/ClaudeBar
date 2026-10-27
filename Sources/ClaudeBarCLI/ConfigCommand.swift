import ArgumentParser
import ClaudeBarCore
import Foundation

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change the settings every account shares.",
        discussion: """
            Without arguments, shows the settings. Each takes a value:

              auto-switch on|off
                  Move the login before the active account reaches a limit.
              session-limit <percent>
                  Default session limit: \(SettingsChange.list(UsageSettings.switchPercentChoices)).
              weekly-limit <percent>
                  Default weekly limit: \(SettingsChange.list(UsageSettings.weeklyPercentChoices)).
              refresh-interval <minutes>
                  Time between usage fetches: \(SettingsChange.list(UsageSettings.refreshIntervalChoices.map { Int($0 / 60) })).
              work-days <days>
                  For example mon-fri, or mon,wed,fri.
              work-hours <start>-<end>
                  For example 9-18, in 24-hour time.
            \(Self.autoUpdateHelp)
            Forecasts start from the work days and hours, then follow the rhythm your usage \
            history shows. `claudebar limits` sets limits for one account.
            """)

    #if os(macOS)
    private static let autoUpdateHelp = ""
    #else
    private static let autoUpdateHelp = """
          auto-update on|off
              Install updates by themselves.

        """
    #endif

    enum Setting: String, ExpressibleByArgument, CaseIterable {
        case autoSwitch = "auto-switch"
        case sessionLimit = "session-limit"
        case weeklyLimit = "weekly-limit"
        case refreshInterval = "refresh-interval"
        case workDays = "work-days"
        case workHours = "work-hours"
        #if !os(macOS)
        case autoUpdate = "auto-update"
        #endif
    }

    @Argument(help: "The setting to change.")
    var setting: Setting?

    @Argument(help: "Its new value.")
    var value: String?

    func run() async throws {
        guard let setting = self.setting else {
            self.show(try await Request.status())
            return
        }
        guard let value = self.value else {
            throw ValidationError("Give \(setting.rawValue) a value. `claudebar config --help` lists them.")
        }
        try await Request.run(.configure(try Self.change(setting, value)))
    }

    private func show(_ status: ControlStatus) {
        let settings = status.engine.settings
        let schedule = settings.workSchedule
        let days = Weekday.localeOrdered().filter(schedule.workdays.contains).map(Self.name).joined(separator: ",")
        print("auto-switch       \(settings.autoSwitchEnabled ? "on" : "off")")
        print("session-limit     \(settings.switchAtSessionPercent)%")
        print("weekly-limit      \(settings.switchAtWeeklyPercent)%")
        print("refresh-interval  \(Int(settings.refreshInterval / 60)) minutes")
        print("work-days         \(days.isEmpty ? "none" : days)")
        print("work-hours        \(schedule.startHour)-\(schedule.endHour)")
        if let autoUpdate = status.autoUpdate {
            print("auto-update       \(autoUpdate ? "on" : "off")")
        }
    }

    private static func change(_ setting: Setting, _ value: String) throws -> SettingsChange {
        switch setting {
        case .autoSwitch:
            return .autoSwitch(try self.toggle(value))
        #if !os(macOS)
        case .autoUpdate:
            return .autoUpdate(try self.toggle(value))
        #endif
        case .sessionLimit:
            return .sessionLimit(try self.number(value, unit: "%"))
        case .weeklyLimit:
            return .weeklyLimit(try self.number(value, unit: "%"))
        case .refreshInterval:
            return .refreshInterval(TimeInterval(try self.number(value, unit: "m") * 60))
        case .workDays:
            return .workdays(try self.days(value))
        case .workHours:
            let bounds = value.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == 2, let start = bounds[0], let end = bounds[1] else {
                throw ValidationError("Give work hours as start-end, e.g. 9-18.")
            }
            return .workHours(start: start, end: end)
        }
    }

    private static func toggle(_ value: String) throws -> Bool {
        guard let toggle = Toggle(rawValue: value.lowercased()) else {
            throw ValidationError("Expected on or off, not \(value).")
        }
        return toggle.isOn
    }

    private static func number(_ value: String, unit: String) throws -> Int {
        guard let number = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: " " + unit))) else {
            throw ValidationError("Expected a number, not \(value).")
        }
        return number
    }

    /// "mon-fri", "mon,wed,fri", or "none".
    private static func days(_ value: String) throws -> Set<Weekday> {
        let text = value.lowercased().trimmingCharacters(in: .whitespaces)
        if text == "none" { return [] }
        var days = Set<Weekday>()
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-").map { self.weekday(String($0)) }
            switch ends.count {
            case 1:
                guard let day = ends[0] else { throw self.unknownDays(value) }
                days.insert(day)
            case 2:
                guard let first = ends[0], let last = ends[1] else { throw self.unknownDays(value) }
                // A range runs forward through the week, wrapping past Saturday.
                var day = first
                days.insert(day)
                while day != last {
                    day = Weekday(rawValue: day.rawValue % 7 + 1)!
                    days.insert(day)
                }
            default:
                throw self.unknownDays(value)
            }
        }
        return days
    }

    private static func weekday(_ text: String) -> Weekday? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return nil }
        return Weekday.allCases.first { self.name($0).hasPrefix(text) || Self.fullName($0).hasPrefix(text) }
    }

    private static func name(_ day: Weekday) -> String {
        String(self.fullName(day).prefix(3))
    }

    private static func fullName(_ day: Weekday) -> String {
        switch day {
        case .sunday: return "sunday"
        case .monday: return "monday"
        case .tuesday: return "tuesday"
        case .wednesday: return "wednesday"
        case .thursday: return "thursday"
        case .friday: return "friday"
        case .saturday: return "saturday"
        }
    }

    private static func unknownDays(_ value: String) -> ValidationError {
        ValidationError("Couldn't read \(value) as days. Try mon-fri, or mon,wed,fri.")
    }
}
