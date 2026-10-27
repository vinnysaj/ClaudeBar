import Foundation

/// Everything a ClaudeBar client shows, as of one moment.
public struct EngineState: Sendable, Codable {
    /// Nil until the stored accounts have been read.
    public var snapshot: AccountsSnapshot?
    public var isRefreshing: Bool
    /// How far the cost scan has got, while one runs.
    public var scanProgress: ScanProgress?
    public var signIn: SignInState?
    /// How the last sign-in ended, until the next one starts.
    public var lastSignIn: SignInResult?
    public var settings: UsageSettings
}

/// A sign-in running in the claude CLI beside the live login.
public struct SignInState: Sendable, Codable, Equatable {
    public let id: UUID
    /// The account being signed back into; nil when adding one.
    public let accountId: String?
    public let email: String?
    /// The Mac panel started it, so the panel hands the page to a browser.
    /// Anyone else, the CLI or the tray, hands it on itself.
    public let startedByPanel: Bool
    /// Where to sign in, once the CLI has the pages ready.
    public var pages: SignInPages?
}

/// How a sign-in ended.
public struct SignInResult: Sendable, Codable, Equatable {
    public let id: UUID
    public let succeeded: Bool
    public let message: String
}

public enum EngineError: Error, CustomStringConvertible {
    case signInRunning
    case noSignIn
    case activeAccount
    case failed(String)

    public var description: String {
        switch self {
        case .signInRunning:
            return "A sign-in is already running. Finish or cancel it first."
        case .noSignIn:
            return "No sign-in is running."
        case .activeAccount:
            return "That's the active account. Switch to another one before removing it."
        case .failed(let reason):
            return reason
        }
    }
}

/// Runs ClaudeBar: keeps every account's usage fresh, moves the live login when
/// auto-switching calls for it, prices the local logs, and signs accounts in.
/// The Mac app and the Linux daemon each run one; the Mac panel, the Linux tray
/// and the CLI drive it and watch its state.
public actor Engine {
    public static let shared = Engine()

    private let accounts = AccountManager.shared
    private var state: EngineState
    private var observers: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    private var signInSession: ClaudeSignIn?
    private var lastCostScanAt: Date?

    private static let costScanInterval: TimeInterval = 15 * 60

    private init() {
        self.state = EngineState(
            snapshot: nil, isRefreshing: false, scanProgress: nil, signIn: nil, lastSignIn: nil,
            settings: .saved)
    }

    public var current: EngineState { self.state }

    /// The state now, then after every change. Each observer sees the latest
    /// state rather than every one in between.
    public func updates() -> AsyncStream<EngineState> {
        let (stream, continuation) = AsyncStream<EngineState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        self.observers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeObserver(id) }
        }
        continuation.yield(self.state)
        return stream
    }

    /// Refreshes on the planner's schedule until the task running it is cancelled.
    public func run() async {
        // Renders from the persisted cache before any network round-trip.
        await self.publishSnapshot()
        // A sign-in cut short by quitting leaves its home behind, and possibly credentials.
        await Task.detached { SignInHome.removeLeftovers() }.value
        await self.cycle(force: false)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(AutoSwitchPlanner.pollingTick))
            await self.cycle(force: false)
        }
    }

    /// Fetches every account's usage and rescans costs now.
    public func refresh() async {
        await self.cycle(force: true)
    }

    /// Picks up a login change made outside ClaudeBar, e.g. as the panel opens.
    public func reconcile() async {
        await self.accounts.reconcile()
        await self.publishSnapshot()
    }

    /// Moves the live login to the account.
    public func switchTo(accountId: String) async throws(EngineError) {
        self.state.isRefreshing = true
        self.publish()
        let switched = await self.accounts.switchTo(accountUuid: accountId)
        await self.accounts.refreshUsage(force: false)
        self.state.isRefreshing = false
        await self.publishSnapshot()
        guard switched else {
            throw .failed(await self.accounts.errorMessage() ?? "Couldn't switch accounts.")
        }
    }

    /// Forgets an account and its stored login. The active account stays.
    public func remove(accountId: String) async throws(EngineError) {
        guard await self.accounts.removeAccount(accountUuid: accountId) else { throw .activeAccount }
        await self.publishSnapshot()
    }

    public func setPreferences(_ preferences: AccountPreferences, for accountId: String) async {
        await self.accounts.setPreferences(preferences, for: accountId)
        await self.publishSnapshot()
    }

    public func apply(settings: UsageSettings) async {
        UsageSettings.saved = settings
        self.state.settings = settings
        await self.accounts.apply(settings: settings)
        await self.publishSnapshot()
    }

    // MARK: - Sign-in

    /// Starts signing in beside the live login, so running sessions carry on
    /// untouched: into the account with `accountId` again, or into a new one,
    /// with `email` pre-filled on the sign-in page when given.
    public func startSignIn(accountId: String?, email: String?, startedByPanel: Bool) throws(EngineError) -> UUID {
        guard self.state.signIn == nil else { throw .signInRunning }
        let accountEmail = accountId.flatMap { id in
            self.state.snapshot?.displays.first { $0.id == id }?.account.email
        }
        let email = accountEmail ?? email
        let session = ClaudeSignIn()
        let id = UUID()
        self.signInSession = session
        self.state.signIn = SignInState(
            id: id, accountId: accountId, email: email, startedByPanel: startedByPanel, pages: nil)
        self.state.lastSignIn = nil
        self.publish()
        Task { await self.runSignIn(id: id, session: session, email: email) }
        return id
    }

    /// Hands the running sign-in the code its page ended on.
    public func submitSignInCode(_ text: String) async throws {
        guard let session = self.signInSession else { throw EngineError.noSignIn }
        try await session.submitCode(text)
    }

    /// Stops the sign-in with `id`, or whichever is running when nil, closing
    /// the claude process running it.
    public func cancelSignIn(id: UUID? = nil) async {
        guard let session = self.signInSession, id == nil || id == self.state.signIn?.id else { return }
        await session.cancel()
    }

    private func runSignIn(id: UUID, session: ClaudeSignIn, email: String?) async {
        let result: SignInResult
        do {
            let credentials = try await session.run(email: email) { pages in
                await self.signInPagesReady(id: id, pages: pages)
            }
            let outcome = await self.accounts.adoptSignIn(credentials)
            result = SignInResult(id: id, succeeded: outcome.succeeded, message: outcome.message)
        } catch is CancellationError {
            // Cancelled by whoever started it or by quitting; nothing went wrong.
            result = SignInResult(id: id, succeeded: false, message: "Sign-in cancelled.")
        } catch {
            let outcome = await self.accounts.reportSignInProblem(String(describing: error))
            result = SignInResult(id: id, succeeded: false, message: outcome.message)
        }
        self.signInSession = nil
        self.state.signIn = nil
        self.state.lastSignIn = result
        await self.publishSnapshot()
    }

    private func signInPagesReady(id: UUID, pages: SignInPages) {
        guard self.state.signIn?.id == id else { return }
        self.state.signIn?.pages = pages
        self.publish()
    }

    // MARK: - Refresh cycle

    private func cycle(force: Bool) async {
        guard !self.state.isRefreshing else { return }
        self.state.isRefreshing = true
        self.publish()

        await self.accounts.reconcile()
        await self.accounts.refreshUsage(force: force)
        await self.accounts.autoSwitchIfNeeded()
        await self.publishSnapshot()

        let costIsDue = self.lastCostScanAt.map {
            Date().timeIntervalSince($0) > Self.costScanInterval
        } ?? true
        if force || costIsDue {
            await self.runCostScan()
        }
        self.state.isRefreshing = false
        self.publish()
    }

    private func runCostScan() async {
        // Costs come entirely from the fetched rate table. Without it, leave the
        // last known figures up rather than reporting everything at zero; the next
        // cycle retries, and PricingStore backs the fetch off on its own.
        guard let pricing = await PricingStore.shared.current() else { return }

        let progressTask = Task {
            for await progress in CostScanner.shared.progressStream where !progress.isComplete {
                self.showScanProgress(progress)
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
        self.state.scanProgress = nil
        self.lastCostScanAt = Date()

        await self.accounts.recordCost(cost)
        await self.publishSnapshot()
    }

    private func showScanProgress(_ progress: ScanProgress) {
        self.state.scanProgress = progress
        self.publish()
    }

    // MARK: - Publishing

    private func publishSnapshot() async {
        self.state.snapshot = await self.accounts.snapshot()
        self.publish()
    }

    private func publish() {
        for observer in self.observers.values {
            observer.yield(self.state)
        }
    }

    private func removeObserver(_ id: UUID) {
        self.observers.removeValue(forKey: id)
    }
}
