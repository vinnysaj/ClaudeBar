import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var refreshTask: Task<Void, Never>?
    private var signIn: ClaudeSignIn?
    private var lastCostScanAt: Date?
    private let onCheckForUpdates: (() -> Void)?
    private let hotKeys = HotKeyManager()
    private let model = PanelModel(usageSettings: UsageSettings.saved)
    /// The accounts the menu's items were built for. Everything else updates
    /// through `model` without touching the items.
    private var builtAccountIds: [String]?
    private var headerItem: NSMenuItem?

    private static let costScanInterval: TimeInterval = 15 * 60

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
        self.startPolling()

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
        refresh: { [weak self] in Task { await self?.fetchAndUpdate(force: true) } },
        switchAccount: { [weak self] accountUuid in Task { await self?.switchTo(accountUuid) } },
        signIn: { [weak self] email in self?.startSignIn(email: email) },
        cancelSignIn: { [weak self] in self?.cancelSignIn() },
        removeAccount: { [weak self] accountUuid, email in
            Task { await self?.confirmAndRemove(accountUuid: accountUuid, email: email) }
        },
        updatePreferences: { [weak self] accountUuid, preferences in
            Task { await self?.updatePreferences(preferences, for: accountUuid) }
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

    private func startPolling() {
        self.refreshTask = Task { [weak self] in
            await self?.bootstrap()
            await self?.fetchAndUpdate(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AutoSwitchPlanner.pollingTick))
                await self?.fetchAndUpdate(force: false)
            }
        }
    }

    /// Instant render from the persisted cache before any network round-trip.
    private func bootstrap() async {
        await self.refreshSnapshot()
        // A sign-in cut short by quitting leaves its home behind, and possibly credentials.
        await Task.detached { SignInHome.removeLeftovers() }.value
    }

    private func fetchAndUpdate(force: Bool) async {
        guard !self.model.isRefreshing else { return }
        self.model.isRefreshing = true
        defer { self.model.isRefreshing = false }

        await AccountManager.shared.reconcile()
        await AccountManager.shared.refreshUsage(force: force)
        await AccountManager.shared.autoSwitchIfNeeded()
        await self.refreshSnapshot()

        let costIsDue = self.lastCostScanAt.map {
            Date().timeIntervalSince($0) > Self.costScanInterval
        } ?? true
        if force || costIsDue {
            await self.runCostScan()
        }
    }

    private func refreshSnapshot() async {
        self.model.snapshot = await AccountManager.shared.snapshot()
        self.applyIcon()
        self.rebuildMenuIfNeeded()
    }

    private func runCostScan() async {
        // Costs come entirely from the fetched rate table. Without it, leave the
        // last known figures up rather than reporting everything at zero; the next
        // poll retries, and PricingStore backs the fetch off on its own.
        guard let pricing = await PricingStore.shared.current() else { return }

        let progressTask = Task { [weak self] in
            for await progress in CostScanner.shared.progressStream {
                await MainActor.run {
                    guard let self, !progress.isComplete else { return }
                    self.model.scanProgress = progress
                }
            }
        }

        var cost = await Task.detached { CostScanner.shared.scan(pricing: pricing) }.value
        // A Claude model we can't price usually just means the feed has moved on
        // since we last read it, so pull it again and re-total against the newer
        // rates. A third-party model routed through the CLI never will appear in it,
        // so it isn't worth a request.
        if cost.unpricedModels.contains(where: { $0.hasPrefix("claude-") }),
           let refreshed = await PricingStore.shared.refetchForUnknownModel(),
           refreshed.version != pricing.version
        {
            cost = await Task.detached { CostScanner.shared.scan(pricing: refreshed) }.value
        }
        progressTask.cancel()
        self.model.scanProgress = nil
        self.lastCostScanAt = Date()

        await AccountManager.shared.recordCost(cost)
        await self.refreshSnapshot()
    }

    // MARK: - Account actions

    private func switchTo(_ accountUuid: String) async {
        self.model.isRefreshing = true
        await AccountManager.shared.switchTo(accountUuid: accountUuid)
        await AccountManager.shared.refreshUsage(force: false)
        self.model.isRefreshing = false
        await self.refreshSnapshot()
    }

    private func updatePreferences(_ preferences: AccountPreferences, for accountUuid: String) async {
        await AccountManager.shared.setPreferences(preferences, for: accountUuid)
        await self.refreshSnapshot()
    }

    /// Signs into an account in the claude CLI beside the live login, so running
    /// sessions carry on untouched, then takes the account in.
    private func startSignIn(email: String?) {
        guard self.signIn == nil else { return }
        let signIn = ClaudeSignIn()
        self.signIn = signIn
        self.model.signIn = SignInProgress(email: email, pageURL: nil)
        Task { [weak self] in
            do {
                let credentials = try await signIn.run(email: email) { [weak self] pageURL in
                    self?.model.signIn?.pageURL = pageURL
                }
                await AccountManager.shared.adoptSignIn(credentials)
            } catch is CancellationError {
                // Cancelled from the panel or by quitting; nothing went wrong.
            } catch {
                await AccountManager.shared.reportSignInProblem(String(describing: error))
            }
            self?.signIn = nil
            self?.model.signIn = nil
            await self?.refreshSnapshot()
        }
    }

    /// Stops a sign-in in progress, closing the claude process running it.
    func cancelSignIn() {
        self.signIn?.cancel()
    }

    private func confirmAndRemove(accountUuid: String, email: String) async {
        let alert = NSAlert()
        alert.messageText = "Remove \(email) from ClaudeBar?"
        alert.informativeText = "ClaudeBar forgets this account's stored credentials and usage. The Anthropic account itself is not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await AccountManager.shared.removeAccount(accountUuid: accountUuid)
        await self.refreshSnapshot()
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.hotKeys.suspend()

            self.model.launchAtLogin = SMAppService.mainApp.status == .enabled
            Task { [weak self] in
                await AccountManager.shared.reconcile()
                await self?.refreshSnapshot()
            }
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
        SettingsWindowController.shared.show(handlers: SettingsHandlers(
            applyCombo: { [weak self] combo in self?.applyHotKey(combo) },
            applyUsageSettings: { [weak self] settings in self?.applyUsageSettings(settings) }))
    }

    private func applyUsageSettings(_ settings: UsageSettings) {
        self.model.usageSettings = settings
        UsageSettings.saved = settings
        Task { [weak self] in
            await AccountManager.shared.apply(settings: settings)
            await self?.refreshSnapshot()
        }
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
