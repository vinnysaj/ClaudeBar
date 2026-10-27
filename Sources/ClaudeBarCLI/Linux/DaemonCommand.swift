#if os(Linux)
import ArgumentParser
import ClaudeBarCore
import Foundation

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run ClaudeBar in the foreground.",
        discussion: """
            What `claudebar service install` has systemd run: keeps usage fresh, switches \
            accounts, and answers claudebar and the tray. Logs go to standard error.
            """)

    func run() async throws {
        // Writing a code to a sign-in whose claude has just exited must fail the
        // write, not end the daemon.
        signal(SIGPIPE, SIG_IGN)
        let restart: @Sendable () async -> Void = { Updater.restart() }
        let host = ControlHost(
            autoUpdate: { Updater.installsAutomatically },
            setAutoUpdate: { isOn in Updater.installsAutomatically = isOn },
            update: { progress in try await Updater.shared.update(progress: progress) },
            restart: restart)
        let server = try await ControlServer.bind()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run(engine: .shared, host: host) }
            group.addTask { await Engine.shared.run() }
            group.addTask { await Updater.shared.installAutomatically(restart: restart) }
            // Only the server ends by itself, by failing.
            try await group.next()
            group.cancelAll()
        }
    }
}
#endif
