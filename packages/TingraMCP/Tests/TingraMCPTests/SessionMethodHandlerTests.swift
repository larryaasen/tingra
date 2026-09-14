//
//  SessionMethodHandlerTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraMCP

/// A handler serving one extra method and recording notifications, the
/// way the app's endpoint serves the `tingra/*` methods.
private final class RecordingHandler: SessionMethodHandler {
    /// The notifications received, by method.
    let notifications = Mutex<[String]>([])

    func respond(method: String, params: JSONValue?) async throws -> JSONValue? {
        switch method {
        case "tingra/echo": return params ?? .null
        case "tingra/refuse": throw JSONRPCError(code: .invalidParams, message: "refused")
        case "tingra/explode": throw CocoaError(.fileNoSuchFile)
        default: return nil
        }
    }

    func handleNotification(method: String, params: JSONValue?) async {
        notifications.withLock { $0.append(method) }
    }
}

/// The session's method-handler seam and its outgoing requests: what the
/// app's endpoint adds to the daemon's session without changing it.
@Suite("MCPSession method handler")
struct SessionMethodHandlerTests {
    /// Builds a session with the recording handler over a fresh transport.
    private func makeSession(handler: RecordingHandler) -> (InMemoryMessageTransport, MCPSession, EventBus, StatusSink)
    {
        let eventBus = EventBus()
        let status = StatusSink()
        let transport = InMemoryMessageTransport()
        let session = MCPSession(
            transport: transport, tools: ToolRegistry(), status: status,
            info: DaemonInfo(name: "tingra", version: "0"), eventBus: eventBus, methods: handler)
        return (transport, session, eventBus, status)
    }

    /// Decodes one written line.
    private func decode(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    @Test("a handler's method is answered after initialize")
    func handlerAnswers() async throws {
        let (transport, session, bus, statusSink) = makeSession(handler: RecordingHandler())
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        transport.enqueue(#"{"jsonrpc":"2.0","id":2,"method":"tingra/echo","params":{"a":1}}"#.utf8Data)
        transport.finishInbound()
        await session.run()
        let response = try decode(try #require(transport.writtenLines.dropFirst().first))
        #expect(response["id"] == .int(2))
        #expect(response["result"]?["a"] == .int(1))
        bus.shutdown()
        await statusTask.value
    }

    @Test("a handler's method before initialize returns an invalid-request error")
    func handlerRequiresInitialize() async throws {
        let (transport, session, bus, statusSink) = makeSession(handler: RecordingHandler())
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"tingra/echo","params":{}}"#.utf8Data)
        transport.finishInbound()
        await session.run()
        let response = try decode(try #require(transport.writtenLines.first))
        #expect(response["error"]?["code"] == .int(JSONRPCErrorCode.invalidRequest.rawValue))
        bus.shutdown()
        await statusTask.value
    }

    @Test("a method the handler declines is still method-not-found")
    func unknownMethodStillUnknown() async throws {
        let (transport, session, bus, statusSink) = makeSession(handler: RecordingHandler())
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        transport.enqueue(#"{"jsonrpc":"2.0","id":2,"method":"tingra/nothing"}"#.utf8Data)
        transport.finishInbound()
        await session.run()
        let response = try decode(try #require(transport.writtenLines.dropFirst().first))
        #expect(response["error"]?["code"] == .int(JSONRPCErrorCode.methodNotFound.rawValue))
        bus.shutdown()
        await statusTask.value
    }

    @Test("a thrown JSON-RPC error is answered as that error, any other as internal")
    func thrownErrorsAnswer() async throws {
        let (transport, session, bus, statusSink) = makeSession(handler: RecordingHandler())
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        transport.enqueue(#"{"jsonrpc":"2.0","id":2,"method":"tingra/refuse"}"#.utf8Data)
        transport.enqueue(#"{"jsonrpc":"2.0","id":3,"method":"tingra/explode"}"#.utf8Data)
        transport.finishInbound()
        await session.run()
        let lines = transport.writtenLines
        let refused = try decode(try #require(lines.dropFirst().first))
        #expect(refused["error"]?["code"] == .int(JSONRPCErrorCode.invalidParams.rawValue))
        #expect(refused["error"]?["message"] == .string("refused"))
        let exploded = try decode(try #require(lines.dropFirst(2).first))
        #expect(exploded["error"]?["code"] == .int(JSONRPCErrorCode.internalError.rawValue))
        bus.shutdown()
        await statusTask.value
    }

    @Test("a notification other than initialized reaches the handler")
    func notificationsReachHandler() async throws {
        let handler = RecordingHandler()
        let (transport, session, bus, statusSink) = makeSession(handler: handler)
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8Data)
        transport.enqueue(#"{"jsonrpc":"2.0","method":"tingra/event","params":{"name":"notes.edited"}}"#.utf8Data)
        transport.finishInbound()
        await session.run()
        #expect(handler.notifications.withLock { $0 } == ["tingra/event"])
        bus.shutdown()
        await statusTask.value
    }

    @Test("a request the session sends is settled by the peer's response")
    func outgoingRequestSettles() async throws {
        let (transport, session, bus, statusSink) = makeSession(handler: RecordingHandler())
        let statusTask = bus.attach(statusSink)
        let running = Task { await session.run() }
        let requesting = Task {
            try await session.request("tingra/command.perform", params: .object(["command": "show"]))
        }
        // The request is written first; the peer's answer echoes its id.
        var written = transport.writtenLines
        for _ in 0..<200 where written.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
            written = transport.writtenLines
        }
        let request = try decode(try #require(written.first))
        #expect(request["method"] == .string("tingra/command.perform"))
        let id = try #require(request["id"]?.stringValue)
        #expect(id.hasPrefix("server-"))
        transport.enqueue(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"done":true}}"#.utf8Data)
        let result = try await requesting.value
        #expect(result["done"] == .bool(true))
        transport.finishInbound()
        await running.value
        bus.shutdown()
        await statusTask.value
    }

    @Test("a request the session sends ends as closed when the session ends first")
    func outgoingRequestClosedOnEnd() async throws {
        let (transport, session, bus, statusSink) = makeSession(handler: RecordingHandler())
        let statusTask = bus.attach(statusSink)
        let running = Task { await session.run() }
        let requesting = Task { try await session.request("tingra/command.perform", params: nil) }
        try await Task.sleep(for: .milliseconds(20))
        transport.finishInbound()
        await running.value
        await #expect(throws: SessionRequestError.closed) { try await requesting.value }
        bus.shutdown()
        await statusTask.value
    }
}
