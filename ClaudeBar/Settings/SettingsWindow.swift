import AppKit
import SwiftUI

/// What the Settings window needs from the controller that owns the hotkey and
/// pushes usage settings to the account manager.
struct SettingsHandlers {
    /// Attempts the registration and returns a message to show inline on
    /// failure, or nil on success.
    let applyCombo: (KeyCombo?) -> String?
    let applyUsageSettings: (UsageSettings) -> Void
    let applySignInLinkBehavior: (SignInLinkBehavior) -> Void
}

/// The app's only window. Single-instance: reopening brings the existing one forward
/// rather than stacking duplicates.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(handlers: SettingsHandlers) {
        if let existing = self.window {
            self.bringForward(existing)
            return
        }

        let hostingView = NSHostingView(
            rootView: SettingsView(
                combo: HotKeyManager.saved,
                usage: UsageSettings.saved,
                signInLink: SignInLinkBehavior.saved,
                handlers: handlers))
        hostingView.frame.size = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "ClaudeBar Settings"
        window.contentView = hostingView
        // The controller decides the lifetime; without this the window is deallocated
        // on close and `windowWillClose` would be talking about freed memory.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        self.bringForward(window)
    }

    /// `.accessory` apps have no Dock icon and don't activate on their own, so the
    /// window would open behind whatever the user was looking at.
    private func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { self.window = nil }
    }
}

struct SettingsView: View {
    @State var combo: KeyCombo?
    @State var usage: UsageSettings
    @State var signInLink: SignInLinkBehavior
    @State private var errorMessage: String?

    let handlers: SettingsHandlers

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.shortcutSection
            Divider()
            self.switchingSection
            Divider()
            self.workHoursSection
            Divider()
            self.refreshSection
            Divider()
            self.signInSection
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
        .onChange(of: self.combo) { _, newValue in
            self.errorMessage = self.handlers.applyCombo(newValue)
        }
        .onChange(of: self.usage) { _, newValue in
            self.handlers.applyUsageSettings(newValue)
        }
        .onChange(of: self.signInLink) { _, newValue in
            self.handlers.applySignInLinkBehavior(newValue)
        }
    }

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signing In")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                Text("Sign-in page:")
                    .font(.system(size: 12))
                Picker("Sign-in page", selection: self.$signInLink) {
                    Text("Open in default browser").tag(SignInLinkBehavior.open)
                    Text("Copy link").tag(SignInLinkBehavior.copy)
                }
                .labelsHidden()
                .frame(width: 190)
            }
            Text("Add Account and Sign In run Claude Code's own sign-in without touching the login your claude sessions use. Copy the link to open it in another browser or profile on this Mac; the sign-in finishes there on its own.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard Shortcut")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                Text("Toggle panel:")
                    .font(.system(size: 12))
                ShortcutRecorder(combo: self.$combo)
            }
            if let errorMessage = self.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Press the shortcut from any app to show or hide the ClaudeBar panel.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var switchingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account Switching")
                .font(.system(size: 13, weight: .semibold))
            Toggle("Switch accounts automatically", isOn: self.$usage.autoSwitchEnabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Default session limit:")
                        .font(.system(size: 12))
                    Picker("Default session limit", selection: self.$usage.switchAtSessionPercent) {
                        ForEach(Self.choices(UsageSettings.switchPercentChoices, including: self.usage.switchAtSessionPercent), id: \.self) { percent in
                            Text("\(percent)%").tag(percent)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 72)
                }
                GridRow {
                    Text("Default weekly limit:")
                        .font(.system(size: 12))
                    Picker("Default weekly limit", selection: self.$usage.switchAtWeeklyPercent) {
                        ForEach(Self.choices(UsageSettings.weeklyPercentChoices, including: self.usage.switchAtWeeklyPercent), id: \.self) { percent in
                            Text("\(percent)%").tag(percent)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 72)
                }
            }
            Text("An account stops taking work at either limit: the login moves to the \"Next\" account, the one with room under both of its limits whose weekly window resets soonest. If none has room, the login stays put. Running claude sessions pick up a new account within seconds.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hover an account in the menu to give it its own limits, e.g. a lower weekly limit to keep some of it for claude.ai.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workHoursSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Work Hours")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 4) {
                ForEach(Weekday.localeOrdered(), id: \.self) { day in
                    Toggle(Self.dayInitial(day), isOn: self.workdayBinding(day))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(Calendar.current.weekdaySymbols[day.rawValue - 1])
                }
            }
            HStack(spacing: 10) {
                Text("From")
                    .font(.system(size: 12))
                Picker("Start", selection: self.$usage.workSchedule.startHour) {
                    ForEach(0..<self.usage.workSchedule.endHour, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                Text("to")
                    .font(.system(size: 12))
                Picker("End", selection: self.$usage.workSchedule.endHour) {
                    ForEach((self.usage.workSchedule.startHour + 1)...24, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            Text("Forecasts start from these hours, then follow the rhythm your usage history actually shows.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage Refresh")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                Text("Refresh usage every:")
                    .font(.system(size: 12))
                Picker("Refresh interval", selection: self.$usage.refreshInterval) {
                    ForEach(UsageSettings.refreshIntervalChoices, id: \.self) { interval in
                        Text(Self.intervalLabel(interval)).tag(interval)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
            }
            Text("Every reading is kept for five weeks to learn your pace. While switching automatically, the active account is checked more often as its usage climbs, down to once a minute.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The fixed choices, plus whatever is saved so the picker never shows blank.
    private static func choices(_ fixed: [Int], including saved: Int) -> [Int] {
        Array(Set(fixed + [saved])).sorted()
    }

    private func workdayBinding(_ day: Weekday) -> Binding<Bool> {
        Binding(
            get: { self.usage.workSchedule.workdays.contains(day) },
            set: { isWorkday in
                if isWorkday {
                    self.usage.workSchedule.workdays.insert(day)
                } else {
                    self.usage.workSchedule.workdays.remove(day)
                }
            })
    }

    private static func dayInitial(_ day: Weekday) -> String {
        Calendar.current.veryShortWeekdaySymbols[day.rawValue - 1]
    }

    /// "9 AM", "Noon", "Midnight" for the end of the day.
    private static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0, 24: return "Midnight"
        case 12: return "Noon"
        default: return hour < 12 ? "\(hour) AM" : "\(hour - 12) PM"
        }
    }

    private static func intervalLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
