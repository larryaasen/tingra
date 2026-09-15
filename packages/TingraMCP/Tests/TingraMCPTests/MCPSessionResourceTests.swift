//
//  MCPSessionResourceTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-09-14.
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

/// A resource whose document is a counter a test bumps, signalling each
/// bump to every subscriber — the shape of the app's model-backed
/// resources without a model.
private final class CounterResource: Resource, Sendable {
    let uri = "tingra://counter"
    let name = "counter"
    let title = "Counter"
    let description = "A number that goes up."

    /// The count.
    private let count = Mutex(0)

    /// The subscribers' signals.
    private let signals = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    /// How many change streams have been opened.
    var subscriberCount: Int { signals.withLock { $0.count } }

    func read() async throws -> JSONValue {
        .object(["count": .int(count.withLock { $0 })])
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            signals.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.signals.withLock { $0[id] = nil } }
        }
    }

    /// Bumps the count and signals the change.
    func bump() {
        count.withLock { $0 += 1 }
        for continuation in signals.withLock({ Array($0.values) }) { continuation.yield(()) }
    }
}

/// A resource whose read throws.
private struct BrokenResource: Resource {
    let uri = "tingra://broken"
    let name = "broken"
    let title = "Broken"
    let description = "Cannot be read."
    func read() async throws -> JSONValue { throw CocoaError(.fileNoSuchFile) }
}

/// The session's resource methods: listing, reading, the resource-not-found
/// error, and subscriptions forwarding change signals as updated
/// notifications — over the in-memory transport, no socket.
@Suite("MCPSession resources")
struct MCPSessionResourceTests {
    /// Builds a session over a fresh transport with the counter and the
    /// broken resource registered.
    private func makeSession(
        counter: CounterResource = CounterResource()
    ) async throws -> (InMemoryMessageTransport, MCPSession, EventBus, StatusSink) {
        let eventBus = EventBus()
        let status = StatusSink()
        let resources = ResourceRegistry()
        try await resources.register(counter)
        try await resources.register(BrokenResource())
        let transport = InMemoryMessageTransport()
        let session = MCPSession(
            transport: transport, tools: ToolRegistry(), resources: resources, status: status,
            info: DaemonInfo(name: "tingra", version: "0"), eventBus: eventBus)
        return (transport, session, eventBus, status)
    }

    /// Runs a scripted exchange to completion and returns the written lines.
    private func exchange(_ requests: [String], counter: CounterResource = CounterResource()) async throws -> [String] {
        let (transport, session, bus, statusSink) = try await makeSession(counter: counter)
        let statusTask = bus.attach(statusSink)
        for request in requests { transport.enqueue(request.utf8Data) }
        transport.finishInbound()
        await session.run()
        bus.shutdown()
        await statusTask.value
        return transport.writtenLines
    }

    /// The initialize request.
    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#

    @Test("initialize advertises subscribable resources")
    func capabilities() async throws {
        let lines = try await exchange([initialize])
        let line = try #require(lines.first)

        let result = try #require(decodeLine(line)?["result"])
        #expect(result["capabilities"]?["resources"]?["subscribe"] == .bool(true))
        #expect(result["capabilities"]?["resources"]?["listChanged"] == .bool(false))
    }

    @Test("resources/list returns every resource's descriptor in registration order")
    func lists() async throws {
        let lines = try await exchange([initialize, #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#])
        let line = try #require(lines.last)

        let resources = try #require(decodeLine(line)?["result"]?["resources"]?.arrayValue)
        #expect(resources.map { $0["uri"]?.stringValue } == ["tingra://counter", "tingra://broken"])
        #expect(resources.first?["name"]?.stringValue == "counter")
        #expect(resources.first?["title"]?.stringValue == "Counter")
        #expect(resources.first?["description"]?.stringValue == "A number that goes up.")
        #expect(resources.first?["mimeType"]?.stringValue == "application/json")
    }

    @Test("resources/read returns the document as one JSON text block")
    func reads() async throws {
        let counter = CounterResource()
        counter.bump()
        let lines = try await exchange(
            [initialize, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"tingra://counter"}}"#],
            counter: counter)
        let line = try #require(lines.last)

        let contents = try #require(decodeLine(line)?["result"]?["contents"]?.arrayValue)
        #expect(contents.count == 1)
        #expect(contents.first?["uri"]?.stringValue == "tingra://counter")
        #expect(contents.first?["mimeType"]?.stringValue == "application/json")
        #expect(contents.first?["text"]?.stringValue == #"{"count":1}"#)
    }

    @Test("an unknown URI is answered with MCP's resource-not-found code carrying the URI")
    func unknownURI() async throws {
        let lines = try await exchange([
            initialize, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"tingra://nothing"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"resources/subscribe","params":{"uri":"tingra://nothing"}}"#,
        ])
        for line in lines.dropFirst() {
            let error = try #require(decodeLine(line)?["error"])
            #expect(error["code"] == .int(JSONRPCErrorCode.resourceNotFound.rawValue))
            #expect(error["data"]?["uri"]?.stringValue == "tingra://nothing")
            #expect(error["message"]?.stringValue?.contains("resources/list") == true)
        }
    }

    @Test("a request without a string uri is invalid params")
    func missingURI() async throws {
        let lines = try await exchange([initialize, #"{"jsonrpc":"2.0","id":2,"method":"resources/read"}"#])
        let line = try #require(lines.last)

        let error = try #require(decodeLine(line)?["error"])
        #expect(error["code"] == .int(JSONRPCErrorCode.invalidParams.rawValue))
    }

    @Test("a read that throws is answered as an internal error naming the resource")
    func brokenRead() async throws {
        let lines = try await exchange([
            initialize, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"tingra://broken"}}"#,
        ])
        let line = try #require(lines.last)

        let error = try #require(decodeLine(line)?["error"])
        #expect(error["code"] == .int(JSONRPCErrorCode.internalError.rawValue))
        #expect(error["message"]?.stringValue?.contains("tingra://broken") == true)
    }

    @Test("resource methods before initialize return an invalid-request error")
    func requireInitialize() async throws {
        let lines = try await exchange([#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#])
        let line = try #require(lines.first)

        let error = try #require(decodeLine(line)?["error"])
        #expect(error["code"] == .int(JSONRPCErrorCode.invalidRequest.rawValue))
    }

    @Test("a subscription forwards each change as an updated notification until unsubscribed")
    func subscribes() async throws {
        let counter = CounterResource()
        let (transport, session, bus, statusSink) = try await makeSession(counter: counter)
        let statusTask = bus.attach(statusSink)
        let running = Task { await session.run() }
        transport.enqueue(initialize.utf8Data)
        transport.enqueue(
            #"{"jsonrpc":"2.0","id":2,"method":"resources/subscribe","params":{"uri":"tingra://counter"}}"#.utf8Data)
        #expect(await poll { transport.writtenLines.count == 2 })
        #expect(decodeLine(transport.writtenLines[1])?["result"] == .object([:]))
        #expect(await poll { counter.subscriberCount == 1 })

        counter.bump()
        #expect(await poll { transport.writtenLines.count == 3 })
        let notification = try #require(decodeLine(transport.writtenLines[2]))
        #expect(notification["method"]?.stringValue == "notifications/resources/updated")
        #expect(notification["params"]?["uri"]?.stringValue == "tingra://counter")
        #expect(notification["id"] == nil)

        // Subscribing again is the same subscription; nothing doubles.
        transport.enqueue(
            #"{"jsonrpc":"2.0","id":3,"method":"resources/subscribe","params":{"uri":"tingra://counter"}}"#.utf8Data)
        #expect(await poll { transport.writtenLines.count == 4 })
        #expect(counter.subscriberCount == 1)

        transport.enqueue(
            #"{"jsonrpc":"2.0","id":4,"method":"resources/unsubscribe","params":{"uri":"tingra://counter"}}"#.utf8Data)
        #expect(await poll { transport.writtenLines.count == 5 })
        #expect(await poll { counter.subscriberCount == 0 })
        counter.bump()
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.writtenLines.count == 5)

        transport.finishInbound()
        await running.value
        bus.shutdown()
        await statusTask.value
    }

    @Test("the session's end cancels its subscriptions")
    func endCancelsSubscriptions() async throws {
        let counter = CounterResource()
        let (transport, session, bus, statusSink) = try await makeSession(counter: counter)
        let statusTask = bus.attach(statusSink)
        let running = Task { await session.run() }
        transport.enqueue(initialize.utf8Data)
        transport.enqueue(
            #"{"jsonrpc":"2.0","id":2,"method":"resources/subscribe","params":{"uri":"tingra://counter"}}"#.utf8Data)
        #expect(await poll { counter.subscriberCount == 1 })
        transport.finishInbound()
        await running.value
        #expect(await poll { counter.subscriberCount == 0 })
        bus.shutdown()
        await statusTask.value
    }
}
