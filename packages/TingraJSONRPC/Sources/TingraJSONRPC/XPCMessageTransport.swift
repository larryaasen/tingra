//
//  XPCMessageTransport.swift
//  TingraJSONRPC
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

/// The one Objective-C protocol an `NSXPCConnection` carries between the app
/// and an app-tier plug-in's extension process: whole JSON-RPC payloads, one
/// per XPC message, in both directions. Both sides export an object
/// implementing it and call the other's through the remote proxy. It is a
/// byte channel, not a second RPC protocol — every method name on the wire
/// is JSON-RPC inside the payload (CLAUDE.md, "Never add a second internal
/// RPC protocol"; PLUGINS.md, Decision 14).
///
/// `nonisolated` explicitly: XPC calls an exported object on the
/// connection's own queue, and a module whose default isolation is the main
/// actor would otherwise infer an isolated requirement that traps on
/// delivery (the Phase 0 spike crashed both processes this way).
@objc(TingraXPCMessageChannel)
public nonisolated protocol XPCMessageChannel {
    /// Establishes the connection. An `NSXPCConnection` is only connected
    /// on its first message, so the side that created the connection sends
    /// this once after resuming; the other side ignores it. Without it, a
    /// connection the accepting side only ever reads on is never delivered
    /// to that side at all (Phase 0 spike, row 3).
    func open()

    /// Delivers one JSON-RPC payload.
    ///
    /// - Parameter payload: The message, without framing.
    func deliver(_ payload: Data)
}

/// A ``MessageTransport`` over an `NSXPCConnection`: the app-tier link
/// between Tingra.app and an ExtensionKit extension, carrying the same MCP
/// JSON-RPC the daemon speaks over its socket (PLUGINS.md, Decision 14).
///
/// One transport per connection, on each side. The side that made the
/// connection (`EXHostViewController.makeXPCConnection()` or
/// `AppExtensionProcess.makeXPCConnection()`, both in the app) passes
/// `opening: true` so the transport sends the ``XPCMessageChannel/open()``
/// message that establishes the link; the side that accepted it in the
/// extension passes `opening: false`.
///
/// `@unchecked Sendable`: `NSXPCConnection` is not marked `Sendable` but is
/// documented thread-safe, and the transport touches it only through its
/// own methods; the inbound queue and the failure slot are lock-guarded.
public final class XPCMessageTransport: MessageTransport, @unchecked Sendable {
    /// The connection.
    private let connection: NSXPCConnection

    /// The payloads the peer has delivered, in order.
    private let inbound = AsyncQueue<Data>()

    /// The first error a write's error handler reported, thrown by the next
    /// write: XPC reports send failures asynchronously. A reference box, so
    /// the handler can capture it (a `Mutex` is non-copyable).
    private let failure = FailureBox()

    /// Whether ``close()`` has run.
    private let closed = Mutex(false)

    /// Called when the system reports the peer gone (interruption) or the
    /// connection unusable (invalidation), with which it was.
    private let onEnd: (@Sendable (End) -> Void)?

    /// How a connection ended.
    public enum End: Sendable, Equatable {
        /// The peer process exited or was killed; the connection object may
        /// reconnect on the next message, but the session is over.
        case interrupted

        /// The connection can never be used again.
        case invalidated
    }

    /// Wraps `connection`: sets both interfaces and the exported receiver,
    /// installs the handlers, resumes, and — when `opening` — sends the
    /// establishing message.
    ///
    /// - Parameters:
    ///   - connection: A connection that has not been resumed.
    ///   - opening: Whether this side created the connection.
    ///   - onEnd: Called once when the peer goes away, with how.
    public init(connection: NSXPCConnection, opening: Bool, onEnd: (@Sendable (End) -> Void)? = nil) {
        self.connection = connection
        self.onEnd = onEnd
        let receiver = Receiver(inbound: inbound)
        connection.exportedInterface = NSXPCInterface(with: XPCMessageChannel.self)
        connection.exportedObject = receiver
        connection.remoteObjectInterface = NSXPCInterface(with: XPCMessageChannel.self)
        let inbound = self.inbound
        connection.interruptionHandler = { @Sendable in
            inbound.finish()
            onEnd?(.interrupted)
        }
        connection.invalidationHandler = { @Sendable in
            inbound.finish()
            onEnd?(.invalidated)
        }
        connection.resume()
        if opening {
            channel()?.open()
        }
    }

    /// The remote side's channel, recording the first send failure.
    private func channel() -> (any XPCMessageChannel)? {
        let failure = failure
        return connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            failure.record(error)
        } as? any XPCMessageChannel
    }

    public func readMessage() async throws -> Data? {
        await inbound.next()
    }

    public func writeMessage(_ payload: Data) async throws {
        if let error = failure.first { throw error }
        guard let channel = channel() else { throw XPCMessageTransportError.channelUnavailable }
        channel.deliver(payload)
    }

    public func close() async {
        let wasClosed = closed.withLock { closed -> Bool in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        inbound.finish()
        connection.invalidate()
    }

    /// Holds the first send failure XPC reported.
    private final class FailureBox: Sendable {
        /// The first failure, or nil.
        private let value = Mutex<(any Error)?>(nil)

        /// Records `error` unless one is already held.
        func record(_ error: any Error) {
            value.withLock { if $0 == nil { $0 = error } }
        }

        /// The first failure, or nil.
        var first: (any Error)? { value.withLock { $0 } }
    }

    /// What the peer calls: queues each payload for ``readMessage()``.
    private final class Receiver: NSObject, XPCMessageChannel {
        /// Where delivered payloads go.
        private let inbound: AsyncQueue<Data>

        /// Creates the receiver.
        init(inbound: AsyncQueue<Data>) {
            self.inbound = inbound
        }

        /// The establishing message carries nothing.
        func open() {}

        func deliver(_ payload: Data) {
            inbound.enqueue(payload)
        }
    }
}

/// What an ``XPCMessageTransport`` write can get wrong beyond what XPC
/// reports through its error handler.
public enum XPCMessageTransportError: Error, CustomStringConvertible {
    /// The connection returned no remote proxy conforming to the channel.
    case channelUnavailable

    public var description: String {
        switch self {
        case .channelUnavailable:
            "The XPC connection offered no TingraXPCMessageChannel proxy; the peer is not a Tingra app-tier endpoint."
        }
    }
}
