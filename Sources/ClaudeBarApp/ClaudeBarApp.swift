import AppKit
import ClaudeBarCore
#if canImport(Sparkle)
import Sparkle
#endif

// Sparkle is an Xcode-project dependency only; `swift build` (the dev loop)
// compiles without it and simply gets no updater UI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var controlTask: Task<Void, Never>?
    #if canImport(Sparkle)
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if canImport(Sparkle)
        let updaterController = self.updaterController
        let onCheckForUpdates: (() -> Void)? = { updaterController.checkForUpdates(nil) }
        #else
        let onCheckForUpdates: (() -> Void)? = nil
        #endif

        let host = ControlHost(
            autoUpdate: { nil },
            setAutoUpdate: nil,
            update: { [weak self] _ in
                try await self?.checkForUpdates()
                return UpdateOutcome(
                    message: "ClaudeBar is checking for updates. Its window on this Mac installs one if there is.",
                    restarts: false)
            },
            restart: {})
        self.controlTask = Task {
            do {
                let server = try await ControlServer.bind()
                self.statusItemController = StatusItemController(onCheckForUpdates: onCheckForUpdates)
                try await server.run(engine: .shared, host: host)
            } catch ControlServerError.alreadyRunning {
                Self.alert(
                    "ClaudeBar is already running",
                    "Another copy of ClaudeBar is open, and two would sign each other's accounts out. This one will quit.")
                NSApp.terminate(nil)
            } catch {
                // The app works without the socket; only claudebar can't reach it.
                if self.statusItemController == nil {
                    self.statusItemController = StatusItemController(onCheckForUpdates: onCheckForUpdates)
                }
                Self.alert("The claudebar command can't reach ClaudeBar", "\(error)")
            }
        }
    }

    private static func alert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func checkForUpdates() throws {
        #if canImport(Sparkle)
        self.updaterController.checkForUpdates(nil)
        #else
        throw UpdaterUnavailable()
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The claude process a sign-in runs in would outlive the app.
        Task {
            await Engine.shared.cancelSignIn()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct UpdaterUnavailable: Error, CustomStringConvertible {
    var description: String {
        "This build of ClaudeBar has no updater; release builds update through Sparkle."
    }
}

@main
enum ClaudeBarMain {
    static func main() {
        // Writing a code to a sign-in whose claude has just exited must fail the
        // write, not end the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
