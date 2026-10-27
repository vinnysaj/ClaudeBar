import ArgumentParser
import ClaudeBarCore
import Foundation

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update ClaudeBar to the latest release.",
        discussion: Self.discussion)

    #if os(macOS)
    private static let discussion = "Opens the ClaudeBar app's updater, which installs and relaunches the app, this command included."
    #else
    private static let discussion = """
        Installs the latest release over this one, verified against ClaudeBar's signing \
        key, and restarts the daemon on it. The daemon also does this by itself once a \
        day unless `claudebar config auto-update off`.
        """
    #endif

    func run() async throws {
        do {
            try await ControlClient.withConnection { connection in
                try await connection.send(.update)
                for try await reply in connection.replies {
                    switch reply {
                    case .progress(let step):
                        print(step)
                    case .done(let message):
                        print(message)
                        return
                    case .failed(let message):
                        throw CLIFailure(message)
                    default:
                        throw ControlError.unexpectedReply
                    }
                }
                throw ControlError.disconnected
            }
        } catch ControlError.notRunning {
            #if os(Linux)
            // With no daemon to update itself, update the files in place.
            let outcome = try await Updater.shared.update { step in print(step) }
            print(outcome.message)
            #else
            throw ControlError.notRunning
            #endif
        }
    }
}
