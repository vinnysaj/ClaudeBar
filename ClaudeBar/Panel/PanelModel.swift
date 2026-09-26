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
    /// Signs into `email`'s account beside the live login, or into a new one when nil.
    let signIn: (_ email: String?) -> Void
    let cancelSignIn: () -> Void
    let removeAccount: (_ accountId: String, _ email: String) -> Void
    let updatePreferences: (_ accountId: String, AccountPreferences) -> Void
    let openSettings: () -> Void
    let checkForUpdates: (() -> Void)?
    let quit: () -> Void
}

/// A sign-in running in the claude CLI beside the live login.
struct SignInProgress {
    /// The account being signed back into; nil when adding one.
    let email: String?
    /// The sign-in page, for when the browser didn't open.
    var pageURL: URL?
}
