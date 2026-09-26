import CryptoKit
import Foundation
import os

/// Signs into an Anthropic account with `claude auth login` in a config home of
/// ClaudeBar's own, so the login Claude Code's sessions run on stays as it is.
/// Once the account is signed in, `run` hands back its credentials and deletes
/// what the CLI left behind.
@MainActor
final class ClaudeSignIn {
    /// What the CLI stored for the account it signed into.
    struct Credentials: Sendable {
        /// In the same shape as Claude Code's own keychain item.
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
                return "The clipboard doesn't hold a sign-in code. Copy the code the sign-in page shows, then try again."
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
    /// the sign-in page when given. Rather than opening the page, the CLI hands
    /// it to `onPage`, and exits once the account is signed in. Throws
    /// `CancellationError` after `cancel()`.
    func run(email: String?, onPage: @escaping @MainActor @Sendable (SignInPage) -> Void) async throws -> Credentials {
        do {
            let credentials = try await self.signIn(email: email, onPage: onPage)
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

    /// Hands the CLI the code a manual sign-in page ends on, which it takes as
    /// `code#state`. `text` is checked for that shape first: the CLI answers
    /// anything else by waiting for another try.
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

    private func signIn(email: String?, onPage: @escaping @MainActor @Sendable (SignInPage) -> Void) async throws -> Credentials {
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
        // to open or copy.
        environment["BROWSER"] = SignInHome.browserRecorder.path
        process.environment = environment

        let (status, errors) = try await self.runToExit(process, onPage: onPage)
        self.process = nil
        self.input = nil

        guard !self.isCancelled else { throw CancellationError() }
        guard status == 0 else {
            throw Failure.loginFailed(Self.reason(fromErrors: errors, status: status))
        }
        return try await Task.detached { try SignInHome.collectCredentials() }.value
    }

    private func runToExit(
        _ process: Process, onPage: @escaping @MainActor @Sendable (SignInPage) -> Void) async throws -> (status: Int32, errors: String)
    {
        let transcript = OSAllocatedUnfairLock(initialState: Transcript())
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = Pipe()
        process.standardInput = input
        self.input = input
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let manualPage = transcript.withLock({ $0.appendOutput(data) }) {
                Task { @MainActor [weak self] in
                    await self?.deliverPage(manual: manualPage, to: onPage)
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
            throw error
        }
        output.fileHandleForReading.readabilityHandler = nil
        return (status, await errorText.value)
    }

    /// Hands over the automatic page once the recorder has it, which is right
    /// after the CLI prints the manual one. The manual page is the fallback.
    private func deliverPage(manual: URL, to onPage: @MainActor @Sendable (SignInPage) -> Void) async {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.automaticPageWait
        while clock.now < deadline, !self.isCancelled {
            if let automatic = SignInHome.recordedPage() {
                onPage(SignInPage(url: automatic, endsOnCode: false))
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        guard !self.isCancelled else { return }
        onPage(SignInPage(url: manual, endsOnCode: true))
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

/// Where the account signs in.
struct SignInPage: Sendable, Equatable {
    let url: URL
    /// The page ends on a code to paste back instead of handing the sign-in
    /// back to the CLI by itself.
    let endsOnCode: Bool
}

/// What ClaudeBar does with the sign-in page when a sign-in starts.
enum SignInLinkBehavior: String, Codable, CaseIterable, Sendable {
    /// Opens it in the default browser.
    case open
    /// Copies its link, to open in whichever browser profile belongs to the account.
    case copy

    private static let defaultsKey = "signInLinkBehavior"

    static var saved: SignInLinkBehavior {
        get { Preferences.read(SignInLinkBehavior.self, key: Self.defaultsKey) ?? .open }
        set { Preferences.write(newValue, key: Self.defaultsKey) }
    }
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
/// short leaves its keychain item under a name the next one can clean up.
enum SignInHome {
    private static let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "sign-in")

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("SignIn", isDirectory: true)
    }

    /// The path as the CLI hashes it for the keychain item's name, in NFC.
    static var path: String {
        self.url.path.precomposedStringWithCanonicalMapping
    }

    /// Where the CLI keeps this home's credentials: the name of Claude Code's own
    /// item, then the first 8 hex digits of the SHA-256 of the home's path.
    static var credentialsService: String {
        let digest = SHA256.hash(data: Data(self.path.utf8))
        let prefix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(KeychainStore.liveService)-\(prefix)"
    }

    /// Stands in for the browser: the CLI runs it with the automatic sign-in
    /// page, and it leaves the address in `recordedPageFile`.
    static var browserRecorder: URL { self.url.appendingPathComponent("record-sign-in-page") }
    private static var recordedPageFile: URL { self.url.appendingPathComponent("sign-in-page") }

    /// Creates the home with the browser recorder in it.
    static func prepare() throws {
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
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
            blob = try KeychainStore.readCLIItem(service: self.credentialsService)
        } catch KeychainError.notFound {
            // Without a usable keychain, the CLI writes credentials to a file in the home.
            let fileURL = self.url.appendingPathComponent(".credentials.json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ClaudeSignIn.Failure.credentialsMissing
            }
            blob = try Data(contentsOf: fileURL)
        }
        let claudeJsonURL = self.url.appendingPathComponent(".claude.json")
        let claudeJson = FileManager.default.fileExists(atPath: claudeJsonURL.path)
            ? try Data(contentsOf: claudeJsonURL)
            : nil
        return ClaudeSignIn.Credentials(blob: blob, claudeJson: claudeJson)
    }

    /// Deletes the home and its keychain item, whatever state a sign-in left them in.
    static func removeLeftovers() {
        do {
            try KeychainStore.deleteCLIItem(service: self.credentialsService)
        } catch {
            self.logger.error("Deleting the sign-in keychain item failed: \(String(describing: error), privacy: .public)")
        }
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            try FileManager.default.removeItem(at: self.url)
        } catch {
            self.logger.error("Deleting the sign-in home failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Finds the claude command. ClaudeBar runs as a GUI app, which doesn't get the
/// user's shell PATH.
enum ClaudeCLI {
    private static let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "sign-in")

    /// Where Claude Code's installers put the command.
    private static let knownPaths = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

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
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
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
