import Foundation
import NIOCore
import NIOPosix
#if canImport(os)
import os
#endif

/// What the app or daemon serving the socket does about updates, which the
/// engine knows nothing of and each platform handles its own way.
public struct ControlHost: Sendable {
    /// Whether ClaudeBar installs updates by itself; nil where its updater has its own setting.
    public var autoUpdate: @Sendable () async -> Bool?
    /// Turns automatic updates on or off; nil where its updater has its own setting.
    public var setAutoUpdate: (@Sendable (Bool) async throws -> Void)?
    /// Updates ClaudeBar, reporting each step through `progress`.
    public var update: @Sendable (_ progress: @escaping @Sendable (String) async -> Void) async throws -> UpdateOutcome
    /// Starts over on the updated binary.
    public var restart: @Sendable () async -> Void

    public init(
        autoUpdate: @escaping @Sendable () async -> Bool?,
        setAutoUpdate: (@Sendable (Bool) async throws -> Void)?,
        update: @escaping @Sendable (_ progress: @escaping @Sendable (String) async -> Void) async throws -> UpdateOutcome,
        restart: @escaping @Sendable () async -> Void)
    {
        self.autoUpdate = autoUpdate
        self.setAutoUpdate = setAutoUpdate
        self.update = update
        self.restart = restart
    }
}

public struct UpdateOutcome: Sendable {
    public let message: String
    /// ClaudeBar restarts on the new binary once the client that asked has its answer.
    public let restarts: Bool

    public init(message: String, restarts: Bool) {
        self.message = message
        self.restarts = restarts
    }
}

public enum ControlServerError: Error, CustomStringConvertible {
    case alreadyRunning

    public var description: String {
        "Another ClaudeBar is already running for this user."
    }
}

/// Serves the control socket: answers the CLI and the tray from the engine.
///
/// Holding the socket is what makes a ClaudeBar the only one running for its
/// user, so the engine starts only once `bind` succeeds: two would each refresh
/// the same logins, and a refresh token works once, so one would lose them.
public struct ControlServer: Sendable {
    private static let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "control")

    private let listener: NIOAsyncChannel<ControlChannel, Never>

    /// Claims the socket. Throws `alreadyRunning` when another ClaudeBar serves it.
    public static func bind() async throws -> ControlServer {
        let socket = AppPaths.controlSocket
        try AppPaths.createPrivateDirectory(socket.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: socket.path) {
            if await ControlClient.isServing() { throw ControlServerError.alreadyRunning }
            // Left by a ClaudeBar that didn't shut down cleanly.
            try FileManager.default.removeItem(at: socket)
        }
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(unixDomainSocketPath: socket.path) { channel in
                ControlFraming.wrap(channel)
            }
        return ControlServer(listener: listener)
    }

    /// Serves until the task running it is cancelled.
    public func run(engine: Engine, host: ControlHost) async throws {
        defer { try? FileManager.default.removeItem(at: AppPaths.controlSocket) }
        try await withThrowingDiscardingTaskGroup { group in
            try await self.listener.executeThenClose { connections in
                for try await connection in connections {
                    group.addTask {
                        await Self.serve(connection, engine: engine, host: host)
                    }
                }
            }
        }
    }

    private static func serve(_ connection: ControlChannel, engine: Engine, host: ControlHost) async {
        do {
            let restarts = try await connection.executeThenClose { inbound, outbound in
                let replies = ReplyWriter(outbound: outbound)
                let session = ConnectionSession()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for try await line in inbound {
                        guard let request = try? ControlFraming.decode(ControlRequest.self, from: line) else {
                            try await replies.send(.failed(
                                "ClaudeBar couldn't read that request. Update claudebar and ClaudeBar to the same version."))
                            continue
                        }
                        try await self.handle(
                            request, engine: engine, host: host, replies: replies, session: session, group: &group)
                    }
                    // The client hung up: what it started for itself stops with it.
                    if let id = await session.signInId {
                        await engine.cancelSignIn(id: id)
                    }
                    group.cancelAll()
                }
                return await session.restartsOnHangUp
            }
            // Only now, with the client's answer read, can the process go.
            if restarts {
                await host.restart()
            }
        } catch {
            self.logger.info("Control connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    private static func handle(
        _ request: ControlRequest, engine: Engine, host: ControlHost, replies: ReplyWriter,
        session: ConnectionSession, group: inout ThrowingTaskGroup<Void, any Error>) async throws
    {
        do {
            switch request {
            case .status:
                try await replies.send(.status(await self.status(await engine.current, host: host)))

            case .watch:
                group.addTask {
                    for await state in await engine.updates() {
                        try await replies.send(.status(await self.status(state, host: host)))
                    }
                }

            case .refresh:
                await engine.refresh()
                try await replies.send(.done("Refreshed."))

            case .switchAccount(let selector):
                let display = try await self.resolve(selector, engine: engine)
                try await engine.switchTo(accountId: display.id)
                try await replies.send(.done("Switched to \(display.account.email)."))

            case .removeAccount(let selector):
                let display = try await self.resolve(selector, engine: engine)
                try await engine.remove(accountId: display.id)
                try await replies.send(.done("Removed \(display.account.email) from ClaudeBar."))

            case .configureAccount(let selector, let change):
                let display = try await self.resolve(selector, engine: engine)
                let preferences = try change.applied(to: display.account.preferences)
                await engine.setPreferences(preferences, for: display.id)
                try await replies.send(.done("Saved for \(display.account.email)."))

            case .configure(.autoUpdate(let isOn)):
                guard let setAutoUpdate = host.setAutoUpdate else {
                    throw ControlError.invalidValue(
                        "On the Mac, ClaudeBar's updater keeps its own setting. Check for Updates is at the bottom of the panel.")
                }
                try await setAutoUpdate(isOn)
                try await replies.send(.done(isOn ? "ClaudeBar will install updates by itself." : "ClaudeBar will only update when you run `claudebar update`."))

            case .configure(let change):
                let settings = try change.applied(to: await engine.current.settings)
                await engine.apply(settings: settings)
                try await replies.send(.done("Saved."))

            case .signIn(let selector):
                guard await session.signInId == nil else {
                    throw ControlError.invalidValue("This connection is already signing in.")
                }
                let (accountId, email) = try await self.signInTarget(selector, engine: engine)
                let id = try await engine.startSignIn(accountId: accountId, email: email, startedByPanel: false)
                await session.setSignIn(id)
                try await replies.send(.signInStarted(email: await engine.current.signIn?.email ?? email))
                group.addTask {
                    try await self.followSignIn(id, engine: engine, replies: replies, session: session)
                }

            case .signInCode(let code):
                guard await session.signInId != nil else {
                    throw ControlError.invalidValue("This connection isn't signing in.")
                }
                do {
                    try await engine.submitSignInCode(code)
                    try await replies.send(.codeAccepted)
                } catch {
                    try await replies.send(.codeRejected(String(describing: error)))
                }

            case .update:
                group.addTask {
                    do {
                        let outcome = try await host.update { step in
                            try? await replies.send(.progress(step))
                        }
                        try await replies.send(.done(outcome.message))
                        if outcome.restarts {
                            await session.restartOnHangUp()
                        }
                    } catch {
                        try await replies.send(.failed(String(describing: error)))
                    }
                }
            }
        } catch let error as ControlError {
            try await replies.send(.failed(error.description))
        } catch let error as EngineError {
            try await replies.send(.failed(error.description))
        } catch let error as AccountSelector.Failure {
            try await replies.send(.failed(error.description))
        }
    }

    /// Passes the sign-in's page on once there is one, then how it ended.
    private static func followSignIn(
        _ id: UUID, engine: Engine, replies: ReplyWriter, session: ConnectionSession) async throws
    {
        var hasSentPages = false
        for await state in await engine.updates() {
            if !hasSentPages, state.signIn?.id == id, let pages = state.signIn?.pages {
                hasSentPages = true
                try await replies.send(.signInPages(pages))
            }
            if let result = state.lastSignIn, result.id == id {
                await session.setSignIn(nil)
                try await replies.send(result.succeeded ? .done(result.message) : .failed(result.message))
                return
            }
        }
    }

    private static func status(_ state: EngineState, host: ControlHost) async -> ControlStatus {
        ControlStatus(
            engine: state, version: AppVersion.marketing, build: AppVersion.build,
            autoUpdate: await host.autoUpdate())
    }

    private static func resolve(_ selector: String, engine: Engine) async throws -> AccountDisplay {
        try AccountSelector.resolve(selector, in: await engine.current.snapshot?.displays ?? [])
    }

    /// The account a sign-in is for: one ClaudeBar has, or a new one, pre-filled
    /// with `selector` when that's an email.
    private static func signInTarget(_ selector: String?, engine: Engine) async throws -> (accountId: String?, email: String?) {
        guard let selector else { return (nil, nil) }
        do {
            return (try await self.resolve(selector, engine: engine).id, nil)
        } catch AccountSelector.Failure.noMatch where selector.contains("@") {
            return (nil, selector)
        }
    }
}

/// Sends replies on one connection; tasks working for it send concurrently.
private struct ReplyWriter: Sendable {
    let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>

    func send(_ reply: ControlReply) async throws {
        try await self.outbound.write(ControlFraming.encode(reply))
    }
}

/// What one connection has started that outlives a single request.
private actor ConnectionSession {
    private(set) var signInId: UUID?
    private(set) var restartsOnHangUp = false

    func setSignIn(_ id: UUID?) {
        self.signInId = id
    }

    func restartOnHangUp() {
        self.restartsOnHangUp = true
    }
}
