#if os(Linux)
import ArgumentParser
import ClaudeBarCore
import Foundation

struct ServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Run ClaudeBar in the background with systemd.",
        subcommands: [Install.self, Uninstall.self])

    static let unitName = "claudebar.service"

    static var unitFile: URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return configHome.appendingPathComponent("systemd/user/\(Self.unitName)")
    }

    /// Runs systemctl for the user's own services, failing with what it said.
    static func systemctl(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["systemctl", "--user"] + arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIFailure("systemctl --user \(arguments.joined(separator: " ")) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start ClaudeBar now and whenever you log in.",
            discussion: """
                Installs a systemd user service running `claudebar daemon` from where this \
                claudebar is. On a desktop with claudebar-tray beside it, the tray starts too, \
                and with every desktop session.
                """)

        func run() throws {
            let executable = CurrentExecutable.url
            let unit = """
                [Unit]
                Description=ClaudeBar: Claude Code usage and account switching

                [Service]
                ExecStart="\(executable.path)" daemon
                Restart=always
                RestartSec=5

                [Install]
                WantedBy=default.target

                """
            try FileManager.default.createDirectory(
                at: ServiceCommand.unitFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(unit.utf8).write(to: ServiceCommand.unitFile, options: .atomic)
            try ServiceCommand.systemctl("daemon-reload")
            try ServiceCommand.systemctl("enable", ServiceCommand.unitName)
            // Restart rather than start, so a daemon already running picks up this binary.
            try ServiceCommand.systemctl("restart", ServiceCommand.unitName)
            print("ClaudeBar is running in the background.")

            if self.hasDesktop, FileManager.default.isExecutableFile(atPath: CurrentExecutable.tray.path) {
                try TrayAutostart.enable(tray: CurrentExecutable.tray)
                self.startTray()
                print("The ClaudeBar tray is in your top bar, and starts with every desktop session.")
            }
            if !self.lingers {
                print("""
                    It stops when you log out. To keep it running on a server, let your user \
                    run services while logged out: sudo loginctl enable-linger \(NSUserName())
                    """)
            }
        }

        private var hasDesktop: Bool {
            let environment = ProcessInfo.processInfo.environment
            return environment["DISPLAY"] != nil || environment["WAYLAND_DISPLAY"] != nil
        }

        /// In a session of its own, so closing this terminal leaves it running.
        private func startTray() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["setsid", "-f", CurrentExecutable.tray.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Terminal.printError("Couldn't start the tray (\(error)); it starts at your next login.")
            }
        }

        private var lingers: Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["loginctl", "show-user", NSUserName(), "--property=Linger"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return text.trimmingCharacters(in: .whitespacesAndNewlines) == "Linger=yes"
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop ClaudeBar and stop starting it at login.",
            discussion: "Accounts, settings and history stay, for when it runs again.")

        func run() throws {
            if FileManager.default.fileExists(atPath: ServiceCommand.unitFile.path) {
                try ServiceCommand.systemctl("disable", "--now", ServiceCommand.unitName)
                try FileManager.default.removeItem(at: ServiceCommand.unitFile)
                try ServiceCommand.systemctl("daemon-reload")
            }
            try TrayAutostart.disable()
            print("ClaudeBar no longer runs in the background. A running tray stays until you quit it.")
        }
    }
}
#endif
