//
//  MessageTransport.swift
//  TingraJSONRPC
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import IOSurface
import Synchronization

/// A duplex, message-level channel carrying one JSON-RPC session's traffic.
/// Framing is the transport's concern (newline delimiting on a socket, one
/// XPC message per payload over an `NSXPCConnection`), so callers deal in
/// whole JSON payloads and the session logic stays free of byte handling.
///
/// The daemon's implementation is `SocketMessageTransport` in TingraMCP over
/// an accepted Unix domain socket; the app tier's is ``XPCMessageTransport``
/// over the connection ExtensionKit hands each side (PLUGINS.md, "The app
/// tier's process model"); ``InMemoryMessageTransport`` stands in for tests
/// so a whole session flow is exercised with no socket or process at all,
/// and ``LinkedMessageTransports`` joins two of them into a peer pair.
public protocol MessageTransport: Sendable {
    /// Reads the next message's JSON payload (without any framing), or nil
    /// when the peer has closed the channel (end of stream). A session calls
    /// this sequentially — one read at a time.
    ///
    /// - Throws: An I/O error if the read fails for a reason other than a
    ///   clean close.
    func readMessage() async throws -> Data?

    /// Frames `payload` and writes it to the peer. Writes are serialized so
    /// a response and a notification never interleave on the wire.
    ///
    /// - Throws: An I/O error if the write fails.
    func writeMessage(_ payload: Data) async throws

    /// Closes the channel. Safe to call more than once.
    func close() async
}

/// One message with what rode beside it: the JSON payload, and the
/// `IOSurface` the sender attached, if it attached one.
///
/// A surface is pixels in shared memory — a program frame handed to an
/// app-tier plug-in's process with no copy (PLUGINS.md, "Frames across the
/// boundary") — and cannot be written into JSON, so it travels *beside* the
/// payload in the same message. The payload still says everything about it
/// (the JSON-RPC method, the bus, the time): the attachment is the one
/// value JSON cannot carry, never a second protocol.
public struct SurfaceMessage: Sendable {
    /// The message's JSON payload, without framing.
    public let payload: Data

    /// The surface attached to the message, or nil for a plain message.
    public let surface: IOSurface?

    /// Creates a message.
    ///
    /// - Parameters:
    ///   - payload: The JSON payload.
    ///   - surface: The surface riding beside it, if any.
    public init(payload: Data, surface: IOSurface? = nil) {
        self.payload = payload
        self.surface = surface
    }
}

/// A ``MessageTransport`` that can carry an `IOSurface` beside a message:
/// the XPC transport, whose connection passes a surface between processes
/// as a kernel handle, and the in-memory one that stands in for it in
/// tests. A socket cannot, so the daemon's transport does not conform, and
/// code that wants to send a surface asks whether its transport does.
public protocol SurfaceMessageTransport: MessageTransport {
    /// Reads the next message with its attachment, or nil when the peer
    /// has closed the channel. The surface-aware form of
    /// ``MessageTransport/readMessage()``: a reader calls one or the other,
    /// never both, and ``MessageTransport/readMessage()`` drops any
    /// attachment.
    ///
    /// - Throws: An I/O error if the read fails for a reason other than a
    ///   clean close.
    func readSurfaceMessage() async throws -> SurfaceMessage?

    /// Writes `payload` to the peer with `surface` attached, in order with
    /// every other write.
    ///
    /// - Parameters:
    ///   - payload: The JSON payload.
    ///   - surface: The surface to hand the peer.
    /// - Throws: An I/O error if the write fails.
    func writeMessage(_ payload: Data, surface: IOSurface) async throws
}

/// An in-memory ``MessageTransport`` for tests: the test enqueues inbound
/// payloads the session will read and collects everything the session
/// writes, with no socket, no file descriptors, and no framing on the wire.
public final class InMemoryMessageTransport: SurfaceMessageTransport {
    /// The inbound messages the session reads, in order.
    private let inbound = AsyncQueue<SurfaceMessage>()

    /// Everything the session has written, in order (lock-protected: the
    /// test reads it while the session writes).
    private let written = Mutex<[Data]>([])

    /// Whether ``close()`` has run.
    private let closed = Mutex(false)

    /// Called with every message written, when a peer wants them live (see
    /// ``LinkedMessageTransports``); nil collects them for ``writtenLines``
    /// alone.
    private let onWrite: (@Sendable (SurfaceMessage) -> Void)?

    /// Creates an empty transport. Enqueue inbound payloads with
    /// ``enqueue(_:)`` and finish them with ``finishInbound()``.
    ///
    /// - Parameter onWrite: Called with every written payload, in addition
    ///   to it being collected.
    public init(onWrite: (@Sendable (Data) -> Void)? = nil) {
        guard let onWrite else {
            self.onWrite = nil
            return
        }
        self.onWrite = { message in onWrite(message.payload) }
    }

    /// Creates an empty transport whose peer wants every written message
    /// with its attachment: one side of a linked pair.
    ///
    /// - Parameter onWriteMessage: Called with every written message.
    init(onWriteMessage: @escaping @Sendable (SurfaceMessage) -> Void) {
        self.onWrite = onWriteMessage
    }

    /// Enqueues one inbound JSON payload for the session to read.
    public func enqueue(_ payload: Data) {
        inbound.enqueue(SurfaceMessage(payload: payload))
    }

    /// Enqueues one inbound message, attachment and all.
    public func enqueue(_ message: SurfaceMessage) {
        inbound.enqueue(message)
    }

    /// Signals the peer closing, so the session's read loop ends.
    public func finishInbound() {
        inbound.finish()
    }

    /// The payloads the session has written so far, decoded as UTF-8 text.
    public var writtenLines: [String] {
        written.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Whether the transport has been closed.
    public var isClosed: Bool { closed.withLock { $0 } }

    public func readMessage() async throws -> Data? {
        await inbound.next()?.payload
    }

    public func readSurfaceMessage() async throws -> SurfaceMessage? {
        await inbound.next()
    }

    public func writeMessage(_ payload: Data) async throws {
        written.withLock { $0.append(payload) }
        onWrite?(SurfaceMessage(payload: payload))
    }

    public func writeMessage(_ payload: Data, surface: IOSurface) async throws {
        written.withLock { $0.append(payload) }
        onWrite?(SurfaceMessage(payload: payload, surface: surface))
    }

    public func close() async {
        closed.withLock { $0 = true }
        inbound.finish()
    }
}

/// Two ``InMemoryMessageTransport``s joined so that what one writes the other
/// reads: a client and a server run against each other in one process with
/// no socket, the way an extension's `PlugInConnection` is tested against
/// the app's endpoint (PLUGINS.md, Phase 1 tests).
public enum LinkedMessageTransports {
    /// Creates a joined pair. Closing either side finishes the other's
    /// inbound stream, as a real peer closing would.
    ///
    /// - Returns: The two transports; which is "client" and which "server"
    ///   is the caller's choice.
    public static func makePair() -> (InMemoryMessageTransport, InMemoryMessageTransport) {
        let box = PeerBox()
        let a = InMemoryMessageTransport(onWriteMessage: { message in box.peer(of: .a)?.enqueue(message) })
        let b = InMemoryMessageTransport(onWriteMessage: { message in box.peer(of: .b)?.enqueue(message) })
        box.set(a: a, b: b)
        return (a, b)
    }

    /// Which side of the pair a callback belongs to.
    private enum Side {
        case a
        case b
    }

    /// Holds both sides so each write callback can find its peer; the pair
    /// is created before either transport exists, hence the box.
    private final class PeerBox: Sendable {
        /// The two sides, once set.
        private let sides = Mutex<(a: InMemoryMessageTransport?, b: InMemoryMessageTransport?)>((nil, nil))

        /// Records both sides.
        func set(a: InMemoryMessageTransport, b: InMemoryMessageTransport) {
            sides.withLock { $0 = (a, b) }
        }

        /// The other side of `side`.
        func peer(of side: Side) -> InMemoryMessageTransport? {
            sides.withLock { side == .a ? $0.b : $0.a }
        }
    }
}
