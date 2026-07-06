//
//  MCPSessionTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraMCP

/// A tool that echoes its arguments — a minimal successful tool.
private struct EchoTool: Tool {
    let name = "echo"
    let title = "Echo"
    let description = "Returns its arguments."
    let inputSchema: JSONValue = .object(["type": .string("object")])
    func call(_ arguments: JSONValue) async throws -> JSONValue { arguments }
}

/// A tool that always reports an identifier-keyed failure.
private struct FailingTool: Tool {
    let name = "boom"
    let title = "Boom"
    let description = "Always fails."
    let inputSchema: JSONValue = .object(["type": .string("object")])
    func call(_ arguments: JSONValue) async throws -> JSONValue {
        throw ToolError(identifier: .inputNotFound, message: "there is nothing here")
    }
}

/// The per-connection MCP session: the initialize handshake, tools/list,
/// tools/call dispatch (success and identifier-keyed errors), and status
/// notifications — all exercised over the in-memory transport, no socket.
@Suite("MCPSession")
struct MCPSessionTests {
    /// Builds a session over a fresh in-memory transport with the two test
    /// tools registered.
    private func makeSession() async throws -> (InMemoryMessageTransport, MCPSession, EventBus, StatusSink) {
        let eventBus = EventBus()
        let status = StatusSink()
        let tools = ToolRegistry()
        try await tools.register(EchoTool())
        try await tools.register(FailingTool())
        let transport = InMemoryMessageTransport()
        let session = MCPSession(
            transport: transport,
            tools: tools,
            status: status,
            info: DaemonInfo(name: "tingra", version: "9.9.9-test"),
            eventBus: eventBus
        )
        return (transport, session, eventBus, status)
    }

    @Test("initialize returns the protocol version and the daemon build version")
    func initializeHandshake() async throws {
        let (transport, session, bus, statusSink) = try await makeSession()
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        transport.finishInbound()
        await session.run()

        let response = try #require(transport.writtenLines.first.flatMap(decodeLine))
        let result = try #require(response["result"])
        #expect(result["protocolVersion"] == .string(MCPProtocol.version))
        #expect(result["serverInfo"]?["name"] == .string("tingra"))
        #expect(result["serverInfo"]?["version"] == .string("9.9.9-test"))

        bus.shutdown()
        await statusTask.value
    }

    @Test("tools/list before initialize returns an invalid-request error")
    func toolsListBeforeInitialize() async throws {
        let (transport, session, bus, statusSink) = try await makeSession()
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8Data)
        transport.finishInbound()
        await session.run()

        let response = try #require(transport.writtenLines.first.flatMap(decodeLine))
        #expect(response["error"]?["code"] == .int(JSONRPCErrorCode.invalidRequest.rawValue))

        bus.shutdown()
        await statusTask.value
    }

    @Test("tools/list after initialize lists the registered tools")
    func toolsList() async throws {
        let (transport, session, bus, statusSink) = try await makeSession()
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        transport.enqueue(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8Data)
        transport.finishInbound()
        await session.run()

        let listResponse = try #require(transport.writtenLines.dropFirst().first.flatMap(decodeLine))
        let tools = try #require(listResponse["result"]?["tools"])
        guard case .array(let entries) = tools else {
            Issue.record("tools/list did not return an array")
            return
        }
        let names = entries.compactMap { $0["name"]?.stringValue }
        #expect(names == ["echo", "boom"])

        bus.shutdown()
        await statusTask.value
    }

    @Test("a successful tools/call returns structured content and isError false")
    func toolCallSuccess() async throws {
        let (transport, session, bus, statusSink) = try await makeSession()
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        transport.enqueue(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"hi":"there"}}}"#
                .utf8Data
        )
        transport.finishInbound()
        await session.run()

        let response = try #require(transport.writtenLines.dropFirst().first.flatMap(decodeLine))
        let result = try #require(response["result"])
        #expect(result["isError"] == .bool(false))
        #expect(result["structuredContent"]?["hi"] == .string("there"))

        bus.shutdown()
        await statusTask.value
    }

    @Test("a tool that throws a ToolError returns isError with the stable identifier")
    func toolCallToolError() async throws {
        let (transport, session, bus, statusSink) = try await makeSession()
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        transport.enqueue(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"boom"}}"#.utf8Data)
        transport.finishInbound()
        await session.run()

        let response = try #require(transport.writtenLines.dropFirst().first.flatMap(decodeLine))
        let result = try #require(response["result"])
        #expect(result["isError"] == .bool(true))
        #expect(result["structuredContent"]?["identifier"] == .string(ErrorIdentifier.inputNotFound.rawValue))

        bus.shutdown()
        await statusTask.value
    }

    @Test("calling an unknown tool returns an invalidArgument tool error")
    func toolCallUnknown() async throws {
        let (transport, session, bus, statusSink) = try await makeSession()
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        transport.enqueue(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nope"}}"#.utf8Data)
        transport.finishInbound()
        await session.run()

        let response = try #require(transport.writtenLines.dropFirst().first.flatMap(decodeLine))
        #expect(response["result"]?["isError"] == .bool(true))
        #expect(
            response["result"]?["structuredContent"]?["identifier"] == .string(ErrorIdentifier.invalidArgument.rawValue)
        )

        bus.shutdown()
        await statusTask.value
    }

    @Test("an unknown method returns a method-not-found error")
    func unknownMethod() async throws {
        let (transport, session, bus, statusSink) = try await makeSession()
        let statusTask = bus.attach(statusSink)
        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"do/stuff"}"#.utf8Data)
        transport.finishInbound()
        await session.run()

        let response = try #require(transport.writtenLines.first.flatMap(decodeLine))
        #expect(response["error"]?["code"] == .int(JSONRPCErrorCode.methodNotFound.rawValue))

        bus.shutdown()
        await statusTask.value
    }

    @Test("a status event after initialize is forwarded as an MCP notification")
    func statusNotification() async throws {
        let (transport, session, bus, statusSink) = try await makeSession()
        let statusTask = bus.attach(statusSink)
        let runTask = Task { await session.run() }

        transport.enqueue(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        _ = await poll { transport.writtenLines.contains { $0.contains("protocolVersion") } }

        // Re-emit until the notification appears, tolerating the notifier's
        // subscription starting a beat after the initialize response.
        let delivered = await poll {
            bus.event("stream.stats", domain: .output, params: ["fps": .int(30), "bitrate": .int(4_500_000)])
            return transport.writtenLines.contains { $0.contains("notifications/message") }
        }
        #expect(delivered)

        transport.finishInbound()
        await runTask.value
        bus.shutdown()
        await statusTask.value
    }
}
