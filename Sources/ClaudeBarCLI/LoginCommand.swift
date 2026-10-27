import ArgumentParser
import ClaudeBarCore
import Foundation

struct LoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign an account in, or add a new one.",
        discussion: """
            Runs Claude Code's own sign-in beside the login your claude sessions use, so \
            they carry on untouched. The sign-in page's link goes to your clipboard: over \
            SSH, the clipboard of the machine your terminal runs on. Open it in any \
            browser, sign in, and paste back the code the page ends on.
            """)

    @Argument(help: ArgumentHelp(
        "An account to sign back in (its number, or its email or part of it), or the email of a new one. Omit to add an account.",
        valueName: "account"))
    var account: String?

    @Flag(help: "Open the sign-in page in this machine's browser instead of copying its link.")
    var open = false

    func run() async throws {
        let message = try await ControlClient.withConnection { connection in
            try await connection.send(.signIn(selector: self.account))
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    try await self.follow(connection)
                }
                group.addTask {
                    // Whatever is typed is taken as a code; claude waits for one
                    // for as long as the sign-in runs.
                    for await line in Terminal.inputLines() {
                        let code = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !code.isEmpty else { continue }
                        try await connection.send(.signInCode(code))
                    }
                    return nil
                }
                while let result = try await group.next() {
                    if let message = result {
                        group.cancelAll()
                        return message
                    }
                }
                throw ControlError.disconnected
            }
        }
        print(message)
    }

    /// Prints the sign-in's progress as replies come, returning how it ended.
    private func follow(_ connection: ControlConnection) async throws -> String {
        for try await reply in connection.replies {
            switch reply {
            case .signInStarted(let email):
                print("Signing in to \(email ?? "a new account")...")
            case .signInPages(let pages):
                self.present(pages)
            case .codeAccepted:
                print("Code sent. Finishing the sign-in...")
            case .codeRejected(let reason):
                print(Style.yellow(reason))
                self.prompt()
            case .done(let message):
                return message
            case .failed(let message):
                throw CLIFailure(message)
            case .status, .progress:
                break
            }
        }
        throw ControlError.disconnected
    }

    /// Hands the page over: opened or copied, and printed either way.
    private func present(_ pages: SignInPages) {
        // Only the automatic page's address on this machine finishes by itself,
        // so a browser anywhere else gets the one that ends on a code.
        let isRemote = Terminal.isRemote
        let url = isRemote ? pages.manual : pages.forThisMachine
        let endsOnCode = isRemote || pages.automatic == nil

        print("")
        if self.open, !isRemote, Browser.open(url) {
            print("Opened the sign-in page in your browser:")
        } else {
            switch Clipboard.copy(url.absoluteString) {
            case .copied:
                print("Copied the sign-in link. Paste it into any browser on this machine:")
            case .sentToTerminal:
                let tmuxHint = ProcessInfo.processInfo.environment["TMUX"] == nil
                    ? "" : " (in tmux, that takes `set -g set-clipboard on`)"
                print("Sent the sign-in link to your terminal's clipboard\(tmuxHint). It's also here to copy:")
            case .failed:
                print("Copy the sign-in link:")
            }
        }
        print("")
        print("  \(url.absoluteString)")
        print("")
        if endsOnCode {
            print("Sign in, then paste the code the page ends on.")
        } else {
            print("Sign in; ClaudeBar finishes by itself. If the page ends on a code instead, paste it here.")
        }
        self.prompt()
    }

    private func prompt() {
        print("Code: ", terminator: "")
        fflush(nil)
    }
}
