//
//  TransportTests.swift
//  TingraJSONRPC
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import IOSurface
import Testing

@testable import TingraJSONRPC

/// The message transports: the in-memory pair tests use, and the XPC
/// transport the app tier runs on, exercised in-process over an anonymous
/// listener.
@Suite("Message transports")
struct TransportTests {
    @Test("a linked pair delivers each side's writes to the other's reads")
    func linkedPairDelivers() async throws {
        let (client, server) = LinkedMessageTransports.makePair()
        try await client.writeMessage(Data("{\"from\":\"client\"}".utf8))
        try await server.writeMessage(Data("{\"from\":\"server\"}".utf8))
        let atServer = try await server.readMessage()
        let atClient = try await client.readMessage()
        #expect(atServer?.utf8String == "{\"from\":\"client\"}")
        #expect(atClient?.utf8String == "{\"from\":\"server\"}")
        #expect(client.writtenLines == ["{\"from\":\"client\"}"])
    }

    @Test("closing one side of a linked pair ends the other's reads")
    func linkedPairCloseEndsPeer() async throws {
        let (client, server) = LinkedMessageTransports.makePair()
        await client.close()
        // The peer's inbound is not finished by a close on the other side —
        // a real socket peer would see EOF, and an XPC peer its handler — so
        // the server side is finished explicitly, as the session that owns
        // it does on close.
        server.finishInbound()
        let next = try await server.readMessage()
        #expect(next == nil)
        #expect(client.isClosed)
    }

    @Test("an XPC transport carries payloads both ways over an anonymous listener")
    func xpcTransportRoundTrip() async throws {
        let listener = NSXPCListener.anonymous()
        let accepted = AsyncQueue<XPCMessageTransport>()
        let delegate = AcceptingDelegate { connection in
            accepted.enqueue(XPCMessageTransport(connection: connection, opening: false))
        }
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let clientConnection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        let client = XPCMessageTransport(connection: clientConnection, opening: true)
        // The `open()` the opening side sends is what makes the listener
        // deliver the connection at all (Phase 0 spike, row 3).
        let server = try #require(await accepted.next())

        try await client.writeMessage(Data("{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8))
        let request = try await server.readMessage()
        #expect(request?.utf8String == "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"ping\"}")

        try await server.writeMessage(Data("{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{}}".utf8))
        let response = try await client.readMessage()
        #expect(response?.utf8String == "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{}}")

        await client.close()
        await server.close()
    }

    /// A small BGRA surface, the kind a program frame is backed by.
    private func makeSurface() throws -> IOSurface {
        try #require(
            IOSurface(properties: [
                .width: 16, .height: 9, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,  // 'BGRA'
            ]))
    }

    @Test("a linked pair hands a surface across beside its payload, and a plain read drops it")
    func linkedPairCarriesSurface() async throws {
        let (client, server) = LinkedMessageTransports.makePair()
        let surface = try makeSurface()
        try await server.writeMessage(Data("{\"method\":\"tingra/frame\"}".utf8), surface: surface)
        try await server.writeMessage(Data("{\"method\":\"tingra/meters\"}".utf8))
        try await server.writeMessage(Data("{\"method\":\"tingra/frame\"}".utf8), surface: surface)
        let first = try #require(try await client.readSurfaceMessage())
        #expect(first.payload.utf8String == "{\"method\":\"tingra/frame\"}")
        #expect(first.surface === surface)
        let second = try #require(try await client.readSurfaceMessage())
        #expect(second.surface == nil)
        let third = try await client.readMessage()
        #expect(third?.utf8String == "{\"method\":\"tingra/frame\"}")
        #expect(server.writtenLines.count == 3)
    }

    @Test("an XPC transport hands the peer the very surface attached, not a copy")
    func xpcTransportCarriesSurface() async throws {
        let listener = NSXPCListener.anonymous()
        let accepted = AsyncQueue<XPCMessageTransport>()
        let delegate = AcceptingDelegate { connection in
            accepted.enqueue(XPCMessageTransport(connection: connection, opening: false))
        }
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let clientConnection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        let client = XPCMessageTransport(connection: clientConnection, opening: true)
        let server = try #require(await accepted.next())

        let surface = try makeSurface()
        try await server.writeMessage(Data("{\"method\":\"tingra/frame\"}".utf8), surface: surface)
        let message = try #require(try await client.readSurfaceMessage())
        #expect(message.payload.utf8String == "{\"method\":\"tingra/frame\"}")
        let received = try #require(message.surface)
        #expect(IOSurfaceGetID(received) == IOSurfaceGetID(surface))
        #expect(received.width == 16)
        #expect(received.height == 9)

        await client.close()
        await server.close()
    }

    @Test("invalidating the peer's connection ends an XPC transport's reads and reports it")
    func xpcTransportPeerInvalidationEndsReads() async throws {
        let listener = NSXPCListener.anonymous()
        let accepted = AsyncQueue<XPCMessageTransport>()
        let ends = AsyncQueue<XPCMessageTransport.End>()
        let delegate = AcceptingDelegate { connection in
            accepted.enqueue(XPCMessageTransport(connection: connection, opening: false) { ends.enqueue($0) })
        }
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let clientConnection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        let client = XPCMessageTransport(connection: clientConnection, opening: true)
        let server = try #require(await accepted.next())

        await client.close()
        let next = try await server.readMessage()
        #expect(next == nil)
        let end = await ends.next()
        #expect(end == .invalidated || end == .interrupted)
    }
}

/// Accepts every connection an anonymous listener receives and hands it to
/// the test.
private final class AcceptingDelegate: NSObject, NSXPCListenerDelegate {
    /// Called with each new connection, before it is resumed.
    private let onConnection: @Sendable (NSXPCConnection) -> Void

    /// Creates the delegate.
    init(onConnection: @escaping @Sendable (NSXPCConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        onConnection(newConnection)
        return true
    }
}

extension Data {
    /// The bytes as UTF-8 text, for comparing payloads.
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}

extension String {
    /// The text's UTF-8 bytes, for building payloads.
    var utf8Data: Data { Data(utf8) }
}
