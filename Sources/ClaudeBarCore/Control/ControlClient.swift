import Foundation
import NIOCore
import NIOPosix

/// Talks to the running ClaudeBar over its control socket.
public enum ControlClient {
    /// Sends one request and returns its first reply.
    public static func request(_ request: ControlRequest) async throws -> ControlReply {
        try await self.withConnection { connection in
            try await connection.send(request)
            for try await reply in connection.replies {
                return reply
            }
            throw ControlError.disconnected
        }
    }

    /// Runs `body` on a connection, closing it after. Throws
    /// `ControlError.notRunning` when nothing is listening.
    public static func withConnection<Result: Sendable>(
        _ body: (ControlConnection) async throws -> Result) async throws -> Result
    {
        let channel: ControlChannel
        do {
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connect(unixDomainSocketPath: AppPaths.controlSocket.path) { channel in
                    ControlFraming.wrap(channel)
                }
        } catch {
            throw ControlError.notRunning
        }
        return try await channel.executeThenClose { inbound, outbound in
            try await body(ControlConnection(inbound: inbound, outbound: outbound))
        }
    }

    /// Whether a ClaudeBar answers on the socket.
    static func isServing() async -> Bool {
        (try? await self.withConnection { _ in true }) ?? false
    }
}

public struct ControlConnection: Sendable {
    fileprivate let inbound: NIOAsyncChannelInboundStream<ByteBuffer>
    fileprivate let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>

    public func send(_ request: ControlRequest) async throws {
        try await self.outbound.write(ControlFraming.encode(request))
    }

    /// Replies until ClaudeBar hangs up. A connection's replies can be read once.
    public var replies: AsyncThrowingMapSequence<NIOAsyncChannelInboundStream<ByteBuffer>, ControlReply> {
        self.inbound.map { line in
            do {
                return try ControlFraming.decode(ControlReply.self, from: line)
            } catch {
                throw ControlError.unexpectedReply
            }
        }
    }
}
