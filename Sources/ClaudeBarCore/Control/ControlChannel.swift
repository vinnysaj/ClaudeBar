import Foundation
import NIOCore

/// A control connection: lines in and out, each one JSON value.
typealias ControlChannel = NIOAsyncChannel<ByteBuffer, ByteBuffer>

enum ControlFraming {
    /// Sets a freshly opened socket up to carry lines.
    static func wrap(_ channel: Channel) -> EventLoopFuture<ControlChannel> {
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDecoder()))
            return try ControlChannel(wrappingChannelSynchronously: channel)
        }
    }

    static func encode(_ value: some Encodable) throws -> ByteBuffer {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return ByteBuffer(bytes: data)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from line: ByteBuffer) throws -> Value {
        try JSONDecoder().decode(type, from: Data(line.readableBytesView))
    }
}

/// Splits what arrives into lines, without the newline.
private struct LineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")),
              let line = buffer.readSlice(length: newline - buffer.readerIndex)
        else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 1)
        context.fireChannelRead(Self.wrapInboundOut(line))
        return .continue
    }

    /// A last line without its newline is incomplete, so it's dropped.
    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try self.decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
    }
}
