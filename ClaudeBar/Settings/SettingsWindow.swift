import AppKit
import SwiftUI

/// What the Settings window needs from the controller that owns the hotkey and
/// pushes usage settings to the account manager.
struct SettingsHandlers {
    /// Attempts the registration and returns a message to show inline on
    /// failure, or nil on success.
    let applyCombo: (KeyCombo?) -> String?
    let applyUsageSettings: (UsageSettings) -> Void
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
    @State private var errorMessage: String?

    let handlers: SettingsHandlers

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.shortcutSection
            Divider()
            self.switchingSection
            Divider()
            self.refreshSection
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
        .onChange(of: self.combo) { _, newValue in
            self.errorMessage = self.handlers.applyCombo(newValue)
        }
        .onChange(of: self.usage) { _, newValue in
            self.handlers.applyUsageSettings(newValue)
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
            HStack(spacing: 10) {
                Text("Switch when session usage reaches:")
                    .font(.system(size: 12))
                Picker("Switch threshold", selection: self.$usage.switchAtSessionPercent) {
                    ForEach(self.switchPercentChoices, id: \.self) { percent in
                        Text("\(percent)%").tag(percent)
                    }
                }
                .labelsHidden()
                .frame(width: 72)
            }
            .disabled(!self.usage.autoSwitchEnabled)
            Text("Moves the Claude Code login to the \"Next\" account: one with session room to spare, preferring the soonest weekly reset. Running claude sessions pick up the new account within seconds.")
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
            Text("While switching automatically, the active account is checked more often as its usage climbs, down to once a minute.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The fixed choices, plus whatever is saved so the picker never shows blank.
    private var switchPercentChoices: [Int] {
        Array(Set(UsageSettings.switchPercentChoices + [self.usage.switchAtSessionPercent])).sorted()
    }

    private static func intervalLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
