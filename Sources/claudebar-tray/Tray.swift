import CAppIndicator
import ClaudeBarCore
import Foundation

/// The top bar icon and its menu: a client of the ClaudeBar daemon, as
/// claudebar is.
@MainActor
final class Tray {
    private let indicator: UnsafeMutablePointer<AppIndicator>
    private let menu = MenuView()
    private var status: ControlStatus?
    /// Why there's no status, once connecting has failed.
    private var problem: String?
    private var signIn: TraySignIn?
    private var signInConnection: ControlConnection?
    private var signInTask: Task<Void, Never>?
    private var iconFile: URL?
    private var iconSVG: String?

    private static var iconDirectory: URL {
        AppPaths.caches.appendingPathComponent("tray", isDirectory: true)
    }

    init() {
        self.indicator = app_indicator_new("claudebar", "", APP_INDICATOR_CATEGORY_APPLICATION_STATUS)
        app_indicator_set_title(self.indicator, "ClaudeBar")
        app_indicator_set_status(self.indicator, APP_INDICATOR_STATUS_ACTIVE)
        self.menu.perform = { [unowned self] action in self.perform(action) }
        app_indicator_set_menu(self.indicator, gtkCast(self.menu.root))
        try? FileManager.default.removeItem(at: Self.iconDirectory)
        self.render()
    }

    /// Follows the daemon's state for as long as the tray runs, reconnecting
    /// whenever the daemon restarts.
    func start() {
        Task.detached {
            while true {
                let problem: String
                do {
                    try await ControlClient.withConnection { connection in
                        try await connection.send(.watch)
                        for try await reply in connection.replies {
                            if case .status(let status) = reply {
                                onMainLoop { self.show(status) }
                            }
                        }
                    }
                    problem = ControlError.disconnected.description
                } catch ControlError.notRunning {
                    problem = "ClaudeBar isn't running. Start it with: systemctl --user start claudebar"
                } catch {
                    problem = String(describing: error)
                }
                onMainLoop { self.showProblem(problem) }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func show(_ status: ControlStatus) {
        self.restartIfUpdated(status)
        self.status = status
        self.problem = nil
        self.render()
    }

    private func showProblem(_ problem: String) {
        self.status = nil
        self.problem = problem
        self.render()
    }

    private func render() {
        self.menu.show(TrayMenu.entries(
            status: self.status, problem: self.problem, signIn: self.signIn,
            startsAtLogin: TrayAutostart.isEnabled, now: Date()))
        self.updateIcon()
    }

    /// The active account's usage, as the Mac's menu bar shows it.
    private func updateIcon() {
        let now = Date()
        let active = self.status?.engine.snapshot?.displays.first(where: \.isActive)
        let usage = active?.usage
        let paints = UsageIcon.paints(
            sessionUsed: usage?.session.map { Double($0.effectiveUsedPercent(at: now)) },
            weeklyUsed: usage?.weekly.map { Double($0.effectiveUsedPercent(at: now)) },
            stale: usage == nil || active?.isStale == true)
        // Ubuntu's top bar is dark in light and dark themes alike.
        let svg = UsageIcon.svg(paints, color: "#ffffff")
        guard svg != self.iconSVG else { return }

        // A new file for each icon: the top bar caches them by path.
        let file = Self.iconDirectory.appendingPathComponent("icon-\(UUID().uuidString).svg")
        do {
            try FileManager.default.createDirectory(at: Self.iconDirectory, withIntermediateDirectories: true)
            try Data(svg.utf8).write(to: file)
        } catch {
            FileHandle.standardError.write(Data("Writing the tray icon failed: \(error)\n".utf8))
            return
        }
        app_indicator_set_icon_full(self.indicator, file.path, "ClaudeBar")
        if let previous = self.iconFile {
            try? FileManager.default.removeItem(at: previous)
        }
        self.iconFile = file
        self.iconSVG = svg
    }

    /// An update replaces the tray with the daemon, and the daemon restarts on
    /// its own; this starts the tray over on its new binary, once per release.
    private func restartIfUpdated(_ status: ControlStatus) {
        guard status.build > AppVersion.build else { return }
        let marker = "CLAUDEBAR_TRAY_RESTARTED_FOR"
        guard ProcessInfo.processInfo.environment[marker] != String(status.build) else { return }
        setenv(marker, String(status.build), 1)
        let arguments = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(CurrentExecutable.url.path, arguments)
        // Exec failed: this tray carries on as it is.
    }

    // MARK: - Actions

    private func perform(_ action: TrayAction) {
        switch action {
        case .switchTo(let accountId):
            self.request(.switchAccount(selector: accountId))
        case .signIn(let accountId):
            self.startSignIn(accountId: accountId)
        case .remove(let accountId, let email):
            if Dialog.confirm(
                "Remove \(email) from ClaudeBar?",
                detail: "ClaudeBar forgets this account's stored login and usage. The Anthropic account itself is not affected.",
                action: "_Remove")
            {
                self.request(.removeAccount(selector: accountId))
            }
        case .allowAutoSwitch(let accountId, let allows):
            self.request(.configureAccount(selector: accountId, change: .allowsAutoSwitch(allows)))
        case .refresh:
            self.request(.refresh)
        case .autoSwitch(let isOn):
            self.request(.configure(.autoSwitch(isOn)))
        case .startAtLogin(let isOn):
            do {
                if isOn {
                    try TrayAutostart.enable(tray: CurrentExecutable.url)
                } else {
                    try TrayAutostart.disable()
                }
            } catch {
                Dialog.show("Couldn't change whether the tray starts at login: \(error.localizedDescription)")
            }
            self.render()
        case .openSignInPage:
            if let url = self.signIn?.pages?.forThisMachine, !openInBrowser(url) {
                Dialog.show("Couldn't open a browser. Copy the link and paste it into one instead.")
            }
        case .copySignInLink:
            self.copySignInLink()
        case .pasteSignInCode:
            self.pasteSignInCode()
        case .cancelSignIn:
            // Hanging up cancels the sign-in.
            self.signInTask?.cancel()
        case .quit:
            gtk_main_quit()
        }
    }

    /// Sends a request; what it changes comes back as status, a failure as a dialog.
    private func request(_ request: ControlRequest) {
        Task.detached {
            let failure: String?
            do {
                if case .failed(let message) = try await ControlClient.request(request) {
                    failure = message
                } else {
                    failure = nil
                }
            } catch {
                failure = String(describing: error)
            }
            if let failure {
                onMainLoop { Dialog.show(failure) }
            }
        }
    }

    // MARK: - Sign-in

    private func startSignIn(accountId: String?) {
        guard self.signInTask == nil else { return }
        self.signIn = TraySignIn()
        self.render()
        self.signInTask = Task.detached {
            var failure: String?
            do {
                try await ControlClient.withConnection { connection in
                    try await connection.send(.signIn(selector: accountId))
                    onMainLoop { self.signInConnection = connection }
                    for try await reply in connection.replies {
                        switch reply {
                        case .signInStarted(let email):
                            onMainLoop { self.signInStarted(email: email) }
                        case .signInPages(let pages):
                            onMainLoop { self.signInPagesArrived(pages) }
                        case .codeRejected(let reason):
                            onMainLoop { Dialog.show(reason) }
                        case .done:
                            return
                        case .failed(let message):
                            failure = message
                            return
                        case .status, .progress, .codeAccepted:
                            break
                        }
                    }
                }
            } catch is CancellationError {
                // Cancelled from the menu.
            } catch {
                failure = Task.isCancelled ? nil : String(describing: error)
            }
            let ending = failure
            onMainLoop { self.signInEnded(failure: ending) }
        }
    }

    private func signInStarted(email: String?) {
        self.signIn?.email = email
        self.render()
    }

    /// Copies the link straight away, as claudebar does, for whichever browser
    /// or profile the account belongs to.
    private func signInPagesArrived(_ pages: SignInPages) {
        self.signIn?.pages = pages
        self.copySignInLink()
    }

    private func copySignInLink() {
        guard let url = self.signIn?.pages?.forThisMachine else { return }
        Clipboard.copy(url.absoluteString)
        self.signIn?.isLinkCopied = true
        self.render()
    }

    private func pasteSignInCode() {
        guard let connection = self.signInConnection else { return }
        guard let code = Clipboard.text(), !code.isEmpty else {
            Dialog.show("The clipboard is empty. Copy the code the sign-in page ends on, then try again.")
            return
        }
        Task.detached {
            do {
                try await connection.send(.signInCode(code))
            } catch {
                let message = "Couldn't hand the code to ClaudeBar: \(error)"
                onMainLoop { Dialog.show(message) }
            }
        }
    }

    private func signInEnded(failure: String?) {
        self.signInTask = nil
        self.signInConnection = nil
        self.signIn = nil
        self.render()
        if let failure {
            Dialog.show(failure)
        }
    }
}
