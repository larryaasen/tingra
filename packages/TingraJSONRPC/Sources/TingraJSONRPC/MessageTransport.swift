//
//  MessageTransport.swift
//  TingraJSONRPC
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
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

/// An in-memory ``MessageTransport`` for tests: the test enqueues inbound
/// payloads the session will read and collects everything the session
/// writes, with no socket, no file descriptors, and no framing on the wire.
public final class InMemoryMessageTransport: MessageTransport {
    /// The inbound payloads the session reads, in order.
    private let inbound = AsyncQueue<Data>()

    /// Everything the session has written, in order (lock-protected: the
    /// test reads it while the session writes).
    private let written = Mutex<[Data]>([])

    /// Whether ``close()`` has run.
    private let closed = Mutex(false)

    /// Called with every payload written, when a peer wants them live (see
    /// ``LinkedMessageTransports``); nil collects them for ``writtenLines``
    /// alone.
    private let onWrite: (@Sendable (Data) -> Void)?

    /// Creates an empty transport. Enqueue inbound payloads with
    /// ``enqueue(_:)`` and finish them with ``finishInbound()``.
    ///
    /// - Parameter onWrite: Called with every written payload, in addition
    ///   to it being collected.
    public init(onWrite: (@Sendable (Data) -> Void)? = nil) {
        self.onWrite = onWrite
    }

    /// Enqueues one inbound JSON payload for the session to read.
    public func enqueue(_ payload: Data) {
        inbound.enqueue(payload)
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
        await inbound.next()
    }

    public func writeMessage(_ payload: Data) async throws {
        written.withLock { $0.append(payload) }
        onWrite?(payload)
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
        let a = InMemoryMessageTransport { payload in box.peer(of: .a)?.enqueue(payload) }
        let b = InMemoryMessageTransport { payload in box.peer(of: .b)?.enqueue(payload) }
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
