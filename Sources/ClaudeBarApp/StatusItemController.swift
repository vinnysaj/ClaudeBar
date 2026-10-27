import AppKit
import ClaudeBarCore
import ServiceManagement
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var engineTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private let onCheckForUpdates: (() -> Void)?
    private let hotKeys = HotKeyManager()
    private let model = PanelModel(usageSettings: UsageSettings.saved)
    /// The accounts the menu's items were built for. Everything else updates
    /// through `model` without touching the items.
    private var builtAccountIds: [String]?
    private var headerItem: NSMenuItem?

    init(onCheckForUpdates: (() -> Void)? = nil) {
        self.onCheckForUpdates = onCheckForUpdates
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()
        self.menu.delegate = self
        self.statusItem.menu = self.menu
        // Key equivalents only match *enabled* items, and AppKit's auto-enabling has
        // nothing to validate on items whose custom views supply the whole UI.
        self.menu.autoenablesItems = false
        self.model.launchAtLogin = SMAppService.mainApp.status == .enabled

        self.setIcon(sessionUsed: nil, weeklyUsed: nil, stale: true)
        self.rebuildMenuIfNeeded()
        self.observeTask = Task { [weak self] in
            for await state in await Engine.shared.updates() {
                self?.apply(state)
            }
        }
        self.engineTask = Task {
            await Engine.shared.run()
        }

        self.hotKeys.onFire = { [weak self] in self?.openPanel() }
        if let saved = HotKeyManager.saved {
            do {
                try self.hotKeys.register(saved)
            } catch {
                // A combo the OS now refuses (a newly conflicting app, or Sequoia's
                // modifier rule after an upgrade) leaves the shortcut inert; Settings
                // reports the reason when the user next records one.
                NSLog("Couldn't register saved hotkey \(saved.displayString): \(error)")
            }
        }
    }

    private lazy var actions = PanelActions(
        toggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
        refresh: { [weak self] in self?.refresh() },
        switchAccount: { [weak self] accountUuid in self?.switchTo(accountUuid) },
        signIn: { [weak self] accountId in self?.startSignIn(accountId: accountId) },
        cancelSignIn: { [weak self] in self?.cancelSignIn() },
        openSignInPage: { [weak self] in self?.openSignInPage() },
        copySignInLink: { [weak self] in self?.copySignInLink() },
        pasteSignInCode: { [weak self] in self?.pasteSignInCode() },
        removeAccount: { [weak self] accountUuid, email in
            Task { await self?.confirmAndRemove(accountUuid: accountUuid, email: email) }
        },
        updatePreferences: { [weak self] accountUuid, preferences in
            self?.updatePreferences(preferences, for: accountUuid)
        },
        openSettings: { [weak self] in self?.openSettings() },
        checkForUpdates: self.onCheckForUpdates,
        quit: { NSApplication.shared.terminate(nil) })

    /// Lays the menu out as a header, one item per account, costs and pace, and
    /// a footer. Every account and the costs open a hover panel, which AppKit
    /// only offers per item. Items are rebuilt only when the roster changes:
    /// rebuilding closes whatever hover panel is open.
    private func rebuildMenuIfNeeded() {
        let accountIds = self.model.snapshot?.displays.map(\.id) ?? []
        guard accountIds != self.builtAccountIds else { return }
        self.builtAccountIds = accountIds
        self.menu.removeAllItems()

        let width = PanelLayout.width
        let header = HostedMenuItem.make(width: width) {
            PanelHeaderView(model: self.model, actions: self.actions)
        }
        self.headerItem = header
        self.applyKeyEquivalent()
        self.menu.addItem(header)

        for (index, accountId) in accountIds.enumerated() {
            let row = HostedMenuItem.make(width: width) {
                AccountRow(accountId: accountId, showsDivider: index > 0, model: self.model, actions: self.actions)
            }
            row.submenu = HostedMenuItem.submenu(width: PanelLayout.detailWidth) {
                AccountDetailView(accountId: accountId, model: self.model, actions: self.actions)
            }
            self.menu.addItem(row)
        }

        let costPace = HostedMenuItem.make(width: width) { CostPaceRow(model: self.model) }
        costPace.submenu = HostedMenuItem.submenu(width: PanelLayout.detailWidth) {
            CostPaceDetailView(model: self.model)
        }
        self.menu.addItem(costPace)

        self.menu.addItem(HostedMenuItem.make(width: width) {
            PanelFooterView(model: self.model, actions: self.actions)
        })
    }

    /// How the panel closes from the keyboard. NSMenu matches key equivalents
    /// against its items from inside the tracking loop, and selecting an item
    /// dismisses the menu — so the action itself has nothing to do. The hosting
    /// view covers the row, so the equivalent never renders.
    private func applyKeyEquivalent() {
        guard let headerItem = self.headerItem else { return }
        if let combo = self.hotKeys.combo {
            headerItem.keyEquivalent = combo.keyEquivalent
            headerItem.keyEquivalentModifierMask = combo.keyEquivalentModifierMask
            headerItem.target = self
            headerItem.action = #selector(self.dismissViaKeyEquivalent)
        } else {
            headerItem.keyEquivalent = ""
            headerItem.keyEquivalentModifierMask = []
            headerItem.target = nil
            headerItem.action = nil
        }
    }

    private func setIcon(sessionUsed: Double?, weeklyUsed: Double?, stale: Bool) {
        self.statusItem.button?.image = IconRenderer.makeIcon(
            sessionUsed: sessionUsed,
            weeklyUsed: weeklyUsed,
            stale: stale)
    }

    /// Icon reflects the ACTIVE account only.
    private func applyIcon() {
        guard let active = self.model.snapshot?.displays.first(where: \.isActive),
              let usage = active.usage
        else {
            self.setIcon(sessionUsed: nil, weeklyUsed: nil, stale: true)
            return
        }
        let now = Date()
        self.setIcon(
            sessionUsed: usage.session.map { Double($0.effectiveUsedPercent(at: now)) },
            weeklyUsed: usage.weekly.map { Double($0.effectiveUsedPercent(at: now)) },
            stale: active.isStale)
    }

    /// Shows what the engine reports. A sign-in started from the panel also gets
    /// its page handed to the browser here, once claude has one ready.
    private func apply(_ state: EngineState) {
        self.model.snapshot = state.snapshot
        self.model.isRefreshing = state.isRefreshing
        self.model.scanProgress = state.scanProgress
        self.model.usageSettings = state.settings

        var pageArrived = false
        if let signIn = state.signIn {
            var progress = self.model.signIn.flatMap { $0.id == signIn.id ? $0 : nil }
                ?? SignInProgress(id: signIn.id, accountId: signIn.accountId, email: signIn.email)
            if let pages = signIn.pages, progress.page == nil {
                progress.page = SignInPage(url: pages.forThisMachine, endsOnCode: pages.automatic == nil)
                pageArrived = signIn.startedByPanel
            }
            self.model.signIn = progress
        } else {
            self.model.signIn = nil
        }

        self.applyIcon()
        self.rebuildMenuIfNeeded()
        if pageArrived {
            self.presentSignInPage()
        }
    }

    // MARK: - Account actions

    private func refresh() {
        Task { await Engine.shared.refresh() }
    }

    private func switchTo(_ accountUuid: String) {
        // A switch that fails says why in the panel's banner.
        Task { try? await Engine.shared.switchTo(accountId: accountUuid) }
    }

    private func updatePreferences(_ preferences: AccountPreferences, for accountUuid: String) {
        Task { await Engine.shared.setPreferences(preferences, for: accountUuid) }
    }

    /// Signs into an account in the claude CLI beside the live login, so running
    /// sessions carry on untouched, then takes the account in.
    private func startSignIn(accountId: String?) {
        Task {
            do {
                _ = try await Engine.shared.startSignIn(accountId: accountId, email: nil, startedByPanel: true)
            } catch {
                self.showAlert(String(describing: error))
            }
        }
    }

    /// Stops a sign-in in progress, closing the claude process running it.
    private func cancelSignIn() {
        Task { await Engine.shared.cancelSignIn() }
    }

    /// Hands the sign-in page over the way Settings asks: opened in the default
    /// browser, or copied for whichever browser the user pastes it into.
    private func presentSignInPage() {
        switch SignInLinkBehavior.saved {
        case .open:
            self.openSignInPage()
        case .copy:
            self.copySignInLink()
        }
    }

    private func openSignInPage() {
        guard let page = self.model.signIn?.page else { return }
        if NSWorkspace.shared.open(page.url) {
            self.model.signIn?.problem = nil
        } else {
            self.model.signIn?.problem = "Couldn't open a browser. Copy the link and paste it into one instead."
        }
    }

    private func copySignInLink() {
        guard let page = self.model.signIn?.page else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(page.url.absoluteString, forType: .string) {
            self.model.signIn?.isLinkCopied = true
            self.model.signIn?.problem = nil
        } else {
            self.model.signIn?.problem = "Couldn't copy the link to the clipboard."
        }
    }

    private func pasteSignInCode() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        Task {
            do {
                try await Engine.shared.submitSignInCode(text)
                self.model.signIn?.problem = nil
            } catch {
                self.model.signIn?.problem = String(describing: error)
            }
        }
    }

    private func confirmAndRemove(accountUuid: String, email: String) async {
        let alert = NSAlert()
        alert.messageText = "Remove \(email) from ClaudeBar?"
        alert.informativeText = "ClaudeBar forgets this account's stored credentials and usage. The Anthropic account itself is not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try await Engine.shared.remove(accountId: accountUuid)
        } catch {
            self.showAlert(String(describing: error))
        }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.hotKeys.suspend()

            self.model.launchAtLogin = SMAppService.mainApp.status == .enabled
            Task { await Engine.shared.reconcile() }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.hotKeys.resume()
        }
    }

    // MARK: - Hotkey

    /// The hotkey only ever opens: it is suspended while the menu is up, and the
    /// menu item's key equivalent handles the closing press.
    private func openPanel() {
        self.statusItem.button?.performClick(nil)
    }

    /// Reaching this method means the menu already dismissed itself by selecting the
    /// item; the key equivalent's whole job is that dismissal.
    @objc private func dismissViaKeyEquivalent() {}

    private func openSettings() {
        // The panel is a menu with a tracking loop; left up, the window opens
        // behind it and the shortcut recorder never sees a keystroke.
        self.menu.cancelTracking()
        SettingsWindowController.shared.show(model: self.model, handlers: SettingsHandlers(
            applyCombo: { [weak self] combo in self?.applyHotKey(combo) },
            applyUsageSettings: { [weak self] settings in self?.applyUsageSettings(settings) },
            applySignInLinkBehavior: { behavior in SignInLinkBehavior.saved = behavior }))
    }

    private func applyUsageSettings(_ settings: UsageSettings) {
        self.model.usageSettings = settings
        Task { await Engine.shared.apply(settings: settings) }
    }

    /// Returns a message for Settings to show inline, or nil when the combo took.
    private func applyHotKey(_ combo: KeyCombo?) -> String? {
        guard let combo else {
            self.hotKeys.unregister()
            HotKeyManager.saved = nil
            self.applyKeyEquivalent()
            return nil
        }
        do {
            try self.hotKeys.register(combo)
            HotKeyManager.saved = combo
            self.applyKeyEquivalent()
            return nil
        } catch let error as HotKeyManager.RegistrationError {
            if self.hotKeys.combo != nil {
                return "\(error.description) The previous shortcut is still active."
            }
            return error.description
        } catch {
            return "Couldn't register that shortcut."
        }
    }

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Failed to update login item: \(error.localizedDescription)")
        }
        self.model.launchAtLogin = service.status == .enabled
    }
}
