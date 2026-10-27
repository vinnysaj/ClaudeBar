import ArgumentParser
import ClaudeBarCore
import Foundation

/// `claudebar`: drives the running ClaudeBar, the Mac app or the Linux daemon.
public struct ClaudeBarCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "claudebar",
        abstract: "Track Claude Code usage across accounts and switch between them.",
        discussion: Self.discussion,
        version: AppVersion.marketing,
        subcommands: Self.subcommands,
        defaultSubcommand: StatusCommand.self)

    #if os(macOS)
    private static let discussion = "Controls the ClaudeBar app, which must be running."
    private static let subcommands: [any ParsableCommand.Type] = [
        StatusCommand.self, SwitchCommand.self, LoginCommand.self, RemoveCommand.self, RefreshCommand.self,
        LimitsCommand.self, ConfigCommand.self, UpdateCommand.self,
    ]
    #else
    private static let discussion = """
        Controls the ClaudeBar daemon, which `claudebar service install` sets up to run \
        in the background.
        """
    private static let subcommands: [any ParsableCommand.Type] = [
        StatusCommand.self, SwitchCommand.self, LoginCommand.self, RemoveCommand.self, RefreshCommand.self,
        LimitsCommand.self, ConfigCommand.self, UpdateCommand.self, DaemonCommand.self, ServiceCommand.self,
    ]
    #endif

    public init() {}

    /// ArgumentParser's own `main`, except that what the command already printed
    /// is flushed before the error: stdout piped together with stderr would
    /// otherwise show the error first.
    public static func main() async {
        do {
            var command = try self.parseAsRoot()
            if var command = command as? any AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch {
            fflush(nil)
            self.exit(withError: error)
        }
    }
}

/// Requests whose answer is `done` or `failed`.
enum Request {
    /// Sends `request` and prints its answer, or throws it as a failure.
    static func run(_ request: ControlRequest) async throws {
        print(try await self.done(request))
    }

    static func done(_ request: ControlRequest) async throws -> String {
        switch try await ControlClient.request(request) {
        case .done(let message):
            return message
        case .failed(let message):
            throw CLIFailure(message)
        default:
            throw ControlError.unexpectedReply
        }
    }

    static func status() async throws -> ControlStatus {
        guard case .status(let status) = try await ControlClient.request(.status) else {
            throw ControlError.unexpectedReply
        }
        return status
    }
}
