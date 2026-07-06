//
//  MessageTransport.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

/// A duplex, message-level channel carrying one MCP session's JSON-RPC
/// traffic. The framing (newline delimiting) is the transport's concern, so
/// callers deal in whole JSON payloads and the session logic stays free of
/// byte handling.
///
/// The real implementation is ``SocketMessageTransport`` over an accepted
/// Unix domain socket; ``InMemoryMessageTransport`` stands in for tests so
/// the whole session flow (initialize → tools/list → tools/call →
/// notifications) is exercised with no socket at all.
protocol MessageTransport: Sendable {
    /// Reads the next message's JSON payload (without its framing newline),
    /// or nil when the peer has closed the channel (end of stream). The
    /// session calls this sequentially — one read at a time.
    ///
    /// - Throws: An I/O error if the read fails for a reason other than a
    ///   clean close.
    func readMessage() async throws -> Data?

    /// Frames `payload` (appending the delimiter) and writes it to the peer.
    /// Writes are serialized so a response and a notification never
    /// interleave on the wire.
    ///
    /// - Throws: An I/O error if the write fails.
    func writeMessage(_ payload: Data) async throws

    /// Closes the channel. Safe to call more than once.
    func close() async
}

/// An in-memory ``MessageTransport`` for tests: the test enqueues inbound
/// payloads the session will read and collects everything the session
/// writes, with no socket, no file descriptors, and no framing on the wire.
final class InMemoryMessageTransport: MessageTransport {
    /// The inbound payloads the session reads, in order.
    private let inbound = AsyncQueue<Data>()

    /// Everything the session has written, in order (lock-protected: the
    /// test reads it while the session writes).
    private let written = Mutex<[Data]>([])

    /// Whether ``close()`` has run.
    private let closed = Mutex(false)

    /// Creates an empty transport. Enqueue inbound payloads with
    /// ``enqueue(_:)`` and finish them with ``finishInbound()``.
    init() {}

    /// Enqueues one inbound JSON payload for the session to read.
    func enqueue(_ payload: Data) {
        inbound.enqueue(payload)
    }

    /// Signals the peer closing, so the session's read loop ends.
    func finishInbound() {
        inbound.finish()
    }

    /// The payloads the session has written so far, decoded as UTF-8 text.
    var writtenLines: [String] {
        written.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Whether the transport has been closed.
    var isClosed: Bool { closed.withLock { $0 } }

    func readMessage() async throws -> Data? {
        await inbound.next()
    }

    func writeMessage(_ payload: Data) async throws {
        written.withLock { $0.append(payload) }
    }

    func close() async {
        closed.withLock { $0 = true }
        inbound.finish()
    }
}
