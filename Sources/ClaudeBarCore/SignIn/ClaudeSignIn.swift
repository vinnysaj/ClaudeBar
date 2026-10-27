import Foundation
#if canImport(os)
import os
#endif

/// Signs into an Anthropic account with `claude auth login` in a config home of
/// ClaudeBar's own, so the login Claude Code's sessions run on stays as it is.
/// Once the account is signed in, `run` hands back its credentials and deletes
/// what the CLI left behind.
actor ClaudeSignIn {
    /// What the CLI stored for the account it signed into.
    struct Credentials: Sendable {
        /// In the same shape as Claude Code's own stored login.
        let blob: Data
        /// The home's .claude.json, where the CLI records the account's profile.
        let claudeJson: Data?
    }

    enum Failure: Error, CustomStringConvertible {
        case cliNotFound
        case launchFailed(String)
        case loginFailed(String)
        case credentialsMissing
        case notASignInCode
        case codeNotDelivered(String)

        var description: String {
            switch self {
            case .cliNotFound:
                return "Couldn't find the claude command. Install Claude Code, or sign in by running claude and /login."
            case .launchFailed(let reason):
                return "Couldn't start claude to sign in: \(reason)"
            case .loginFailed(let reason):
                return "Sign-in failed: \(reason)"
            case .credentialsMissing:
                return "The sign-in finished, but Claude Code stored the credentials somewhere ClaudeBar doesn't look."
            case .notASignInCode:
                return "That isn't a sign-in code. Copy the code the sign-in page ends on, then try again."
            case .codeNotDelivered(let reason):
                return "Couldn't hand the code to claude: \(reason)"
            }
        }
    }

    /// The CLI once it's running; `cancel()` closes it.
    private var process: Process?
    /// Where the CLI reads a pasted sign-in code from.
    private var input: Pipe?
    private var isCancelled = false

    /// How long after printing the manual page the CLI hands the automatic one
    /// to the browser; it does so straight away, so this is generous.
    private static let automaticPageWait: Duration = .seconds(3)

    /// Signs in and returns the account's credentials, pre-filling `email` on
    /// the sign-in page when given. Rather than opening a page, the CLI's pages
    /// go to `onPages`, and it exits once the account is signed in. Throws
    /// `CancellationError` after `cancel()`.
    func run(email: String?, onPages: @escaping @Sendable (SignInPages) async -> Void) async throws -> Credentials {
        do {
            let credentials = try await self.signIn(email: email, onPages: onPages)
            await Task.detached { SignInHome.removeLeftovers() }.value
            return credentials
        } catch {
            await Task.detached { SignInHome.removeLeftovers() }.value
            throw error
        }
    }

    /// Stops the sign-in, closing the CLI if it's running.
    func cancel() {
        self.isCancelled = true
        self.process?.terminate()
    }

    /// Hands the CLI the code a sign-in page ends on, which it takes as
    /// `code#state` for as long as it waits, whichever page is in use. `text`
    /// is checked for that shape first: the CLI answers anything else by
    /// waiting for another try.
    func submitCode(_ text: String) throws {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = code.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }), !code.contains(where: \.isWhitespace) else {
            throw Failure.notASignInCode
        }
        guard let input = self.input else {
            throw Failure.codeNotDelivered("the sign-in isn't running.")
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data("\(code)\n".utf8))
        } catch {
            throw Failure.codeNotDelivered(error.localizedDescription)
        }
    }

    private func signIn(email: String?, onPages: @escaping @Sendable (SignInPages) async -> Void) async throws -> Credentials {
        guard let executable = await Task.detached(operation: { ClaudeCLI.locate() }).value else {
            throw Failure.cliNotFound
        }
        await Task.detached { SignInHome.removeLeftovers() }.value
        guard !self.isCancelled else { throw CancellationError() }
        do {
            try SignInHome.prepare()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "login"] + (email.map { ["--email", $0] } ?? [])
        process.currentDirectoryURL = SignInHome.url
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = SignInHome.path
        // Names the keychain item after this exact path, rather than after
        // however the CLI resolves its config home.
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = SignInHome.path
        // With this set, the CLI signs in from the token instead of the browser.
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_REFRESH_TOKEN")
        // The CLI prints a manual page, which ends on a code to paste back, and
        // gives the browser an automatic one, which hands the sign-in back to
        // it on its own. The recorder catches the automatic page for ClaudeBar
        // to hand on with the manual one.
        environment["BROWSER"] = SignInHome.browserRecorder.path
        process.environment = environment

        let (status, errors) = try await self.runToExit(process, onPages: onPages)
        self.process = nil
        self.input = nil

        guard !self.isCancelled else { throw CancellationError() }
        guard status == 0 else {
            throw Failure.loginFailed(Self.reason(fromErrors: errors, status: status))
        }
        return try await Task.detached { try SignInHome.collectCredentials() }.value
    }

    private func runToExit(
        _ process: Process, onPages: @escaping @Sendable (SignInPages) async -> Void) async throws -> (status: Int32, errors: String)
    {
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = Pipe()
        process.standardInput = input
        self.input = input

        // Output arrives on a background queue; the stream keeps it in order.
        let (chunks, chunkContinuation) = AsyncStream<Data>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                chunkContinuation.finish()
                return
            }
            chunkContinuation.yield(data)
        }
        let pageWatcher = Task { [weak self] in
            var transcript = Transcript()
            for await chunk in chunks {
                if let manualPage = transcript.appendOutput(chunk) {
                    await self?.deliverPages(manual: manualPage, to: onPages)
                }
            }
        }

        // Read as it comes, so a full pipe never stalls the CLI.
        let errorHandle = errors.fileHandleForReading
        let errorText = Task.detached { String(decoding: errorHandle.readDataToEndOfFile(), as: UTF8.self) }

        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    // Only a launched process can be terminated, so `cancel()`
                    // sees it from here on; a cancel that came first closes it now.
                    self.process = process
                    if self.isCancelled {
                        process.terminate()
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: Failure.launchFailed(error.localizedDescription))
                }
            }
        } catch {
            // Nothing launched to close the pipe, so close it here to end the read.
            try? errors.fileHandleForWriting.close()
            chunkContinuation.finish()
            pageWatcher.cancel()
            throw error
        }
        output.fileHandleForReading.readabilityHandler = nil
        chunkContinuation.finish()
        pageWatcher.cancel()
        return (status, await errorText.value)
    }

    /// Hands over both pages once the recorder has the automatic one, which is
    /// right after the CLI prints the manual one, or the manual one alone when
    /// the automatic one doesn't come.
    private func deliverPages(manual: URL, to onPages: @Sendable (SignInPages) async -> Void) async {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.automaticPageWait
        var automatic: URL?
        while clock.now < deadline, !self.isCancelled {
            automatic = SignInHome.recordedPage()
            if automatic != nil { break }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        guard !self.isCancelled else { return }
        await onPages(SignInPages(manual: manual, automatic: automatic))
    }

    /// The CLI's own explanation from its error output, e.g. "Login failed: …".
    private static func reason(fromErrors errors: String, status: Int32) -> String {
        let firstLine = errors
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else { return "claude exited with status \(status)." }
        let prefix = "Login failed: "
        return firstLine.hasPrefix(prefix) ? String(firstLine.dropFirst(prefix.count)) : firstLine
    }
}

/// Where an account signs in. Both pages sign into the same account; they differ
/// in how the sign-in gets back to the claude CLI running it.
public struct SignInPages: Sendable, Codable, Equatable {
    /// Ends on a code to paste back, so a browser on any machine can finish it.
    public let manual: URL
    /// Usually hands the sign-in back to the CLI by itself, through an address on
    /// the machine running ClaudeBar, so only a browser there can; it can end on a
    /// code too. Nil when the CLI didn't offer one.
    public let automatic: URL?

    /// The page for a browser on the machine running ClaudeBar.
    public var forThisMachine: URL { self.automatic ?? self.manual }
}

/// What the CLI has printed so far.
private struct Transcript: Sendable {
    private var output = ""
    private var hasReportedPage = false

    /// Appends output, returning the manual sign-in page's address the first
    /// time a whole line holds it.
    mutating func appendOutput(_ data: Data) -> URL? {
        self.output += String(decoding: data, as: UTF8.self)
        guard !self.hasReportedPage,
              let lastNewline = self.output.lastIndex(of: "\n"),
              let url = Self.pageURL(in: self.output[..<lastNewline])
        else { return nil }
        self.hasReportedPage = true
        return url
    }

    /// The first https address. The CLI may wrap it in a terminal hyperlink,
    /// whose escape characters end the match.
    private static func pageURL(in text: Substring) -> URL? {
        guard let range = text.range(of: #"https://[^\s\x{1B}\x{07}]+"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[range]))
    }
}

/// The config home sign-ins run in. It's always the same one, so a sign-in cut
/// short leaves its credentials under a name the next one can clean up.
enum SignInHome {
    private static let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "sign-in")

    static var url: URL {
        AppPaths.support.appendingPathComponent("SignIn", isDirectory: true)
    }

    /// The path as the CLI hashes it for the keychain item's name, in NFC.
    static var path: String {
        self.url.path.precomposedStringWithCanonicalMapping
    }

    /// Stands in for the browser: the CLI runs it with the automatic sign-in
    /// page, and it leaves the address in `recordedPageFile`.
    static var browserRecorder: URL { self.url.appendingPathComponent("record-sign-in-page") }
    private static var recordedPageFile: URL { self.url.appendingPathComponent("sign-in-page") }

    /// Creates the home with the browser recorder in it.
    static func prepare() throws {
        try AppPaths.createPrivateDirectory(self.url)
        let script = """
            #!/bin/sh
            printf '%s\\n' "$1" > "$(dirname "$0")/\(self.recordedPageFile.lastPathComponent)"

            """
        try Data(script.utf8).write(to: self.browserRecorder, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.browserRecorder.path)
    }

    /// The automatic sign-in page, once the CLI has handed it to the recorder.
    static func recordedPage() -> URL? {
        guard let data = FileManager.default.contents(atPath: self.recordedPageFile.path) else { return nil }
        let address = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? nil : URL(string: address)
    }

    static func collectCredentials() throws -> ClaudeSignIn.Credentials {
        let blob: Data
        do {
            blob = try CredentialStore.readSignInCredentials(home: self.url)
        } catch CredentialError.notFound {
            throw ClaudeSignIn.Failure.credentialsMissing
        }
        let claudeJsonURL = self.url.appendingPathComponent(".claude.json")
        let claudeJson = FileManager.default.fileExists(atPath: claudeJsonURL.path)
            ? try Data(contentsOf: claudeJsonURL)
            : nil
        return ClaudeSignIn.Credentials(blob: blob, claudeJson: claudeJson)
    }

    /// Deletes the home and its credentials, whatever state a sign-in left them in.
    static func removeLeftovers() {
        do {
            try CredentialStore.deleteSignInCredentials(home: self.url)
        } catch {
            self.logger.error("Deleting the sign-in credentials failed: \(String(describing: error), privacy: .public)")
        }
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            try FileManager.default.removeItem(at: self.url)
        } catch {
            self.logger.error("Deleting the sign-in home failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Finds the claude command. ClaudeBar runs as a GUI app or a service, neither
/// of which gets the user's shell PATH.
enum ClaudeCLI {
    private static let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "sign-in")

    /// Where Claude Code's installers put the command.
    private static let knownPaths = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    #if os(macOS)
    private static let fallbackShell = "/bin/zsh"
    #else
    private static let fallbackShell = "/bin/sh"
    #endif

    static func locate() -> URL? {
        for path in self.knownPaths {
            let expanded = NSString(string: path).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return self.locateThroughLoginShell()
    }

    /// Wherever the user's login shell finds `claude`, for installs elsewhere on
    /// their PATH such as nvm or a custom npm prefix.
    private static func locateThroughLoginShell() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? self.fallbackShell)
        process.arguments = ["-l", "-c", "command -v claude"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            self.logger.error("Starting a login shell to find claude failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // Profile scripts can print before the answer, which is the last line.
        // An alias or function prints its definition instead of a path.
        let lastLine = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let path = lastLine, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
