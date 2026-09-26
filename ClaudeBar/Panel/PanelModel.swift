import Observation

/// Everything the panel shows. The menu's items observe it, so changes redraw
/// in place; rebuilding the menu instead would close any hover panel the user
/// has open.
@MainActor
@Observable
final class PanelModel {
    var snapshot: AccountsSnapshot?
    var scanProgress: ScanProgress?
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
    let addAccount: () -> Void
    let cancelAddAccount: () -> Void
    let removeAccount: (_ accountId: String, _ email: String) -> Void
    let updatePreferences: (_ accountId: String, AccountPreferences) -> Void
    let openSettings: () -> Void
    let checkForUpdates: (() -> Void)?
    let quit: () -> Void
}
