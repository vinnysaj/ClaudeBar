import Foundation
import Observation

/// Everything the panel shows. The menu's items observe it, so changes redraw
/// in place; rebuilding the menu instead would close any hover panel the user
/// has open.
@MainActor
@Observable
final class PanelModel {
    var snapshot: AccountsSnapshot?
    var scanProgress: ScanProgress?
    var signIn: SignInProgress?
    var isRefreshing = false
    var launchAtLogin = false
    var usageSettings: UsageSettings

    init(usageSettings: UsageSettings) {
        self.usageSettings = usageSettings
    }

    func display(for accountId: String) -> AccountDisplay? {
        self.snapshot?.displays.first { $0.id == accountId }
    }

    /// Several accounts make the switching badges meaningful.
    var hasSeveralAccounts: Bool {
        (self.snapshot?.displays.count ?? 0) > 1
    }
}

/// What the panel's controls do.
struct PanelActions {
    let toggleLaunchAtLogin: () -> Void
    let refresh: () -> Void
    let switchAccount: (_ accountId: String) -> Void
    /// Signs into an account beside the live login: the one with `accountId`
    /// again, or a new one when nil.
    let signIn: (_ accountId: String?) -> Void
    let cancelSignIn: () -> Void
    let openSignInPage: () -> Void
    let copySignInLink: () -> Void
    /// Hands the CLI the code on the clipboard, for a sign-in page that ends on one.
    let pasteSignInCode: () -> Void
    let removeAccount: (_ accountId: String, _ email: String) -> Void
    let updatePreferences: (_ accountId: String, AccountPreferences) -> Void
    let openSettings: () -> Void
    let checkForUpdates: (() -> Void)?
    let quit: () -> Void
}

/// A sign-in running in the claude CLI beside the live login.
struct SignInProgress {
    /// The account being signed back into; nil when adding one.
    let accountId: String?
    let email: String?
    /// Where to sign in, once the CLI has it ready.
    var page: SignInPage?
    /// The page's link is on the clipboard.
    var isLinkCopied = false
    /// Why the last try at opening the page, copying its link, or passing back
    /// a code didn't work.
    var problem: String?
}
