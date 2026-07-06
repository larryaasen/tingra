//
//  DaemonSocketTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Darwin
import Foundation
import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraMCP

/// The daemon over a real Unix domain socket, in process: a client connects,
/// runs the MCP handshake, lists and calls a tool, and the daemon shuts down
/// cleanly. Exercises listen/accept/connect, newline framing over real
/// descriptors, and peer verification (same-uid, so it passes) — without the
/// simulator (the streaming round trip lives in scripts/integration-test.sh).
@Suite("Daemon over a socket")
struct DaemonSocketTests {
    @Test("a client round-trips initialize, tools/list, and a tool call, then the daemon shuts down cleanly")
    func roundTrip() async throws {
        // A short socket path — well under the 104-byte sun_path limit.
        let socketPath = "/tmp/tingra-mcp-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let eventBus = EventBus()
        let inputs = InputRegistry()
        let outputs = OutputRegistry()
        let tools = ToolRegistry()
        try await tools.register(DevicesListTool(inputs: inputs))
        let status = StatusSink()
        let coordinator = StreamCoordinator(
            inputs: inputs,
            outputs: outputs,
            status: status,
            eventBus: eventBus,
            clock: FinishingClock(),
            defaults: StreamDefaults(cameraID: { nil }, microphoneID: { nil })
        )

        let daemon = try Daemon.manual(
            socketPath: socketPath,
            tools: tools,
            status: status,
            coordinator: coordinator,
            eventBus: eventBus,
            info: DaemonInfo(name: "tingra", version: "test"),
            idleTimeout: nil
        )
        let runTask = Task { await daemon.run() }

        // Connect a real client over the socket and speak MCP through the
        // same transport the daemon uses on its side.
        let clientDescriptor = try UnixDomainSocket.connect(path: socketPath)
        let client = SocketMessageTransport(descriptor: clientDescriptor)

        try await client.writeMessage(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8Data)
        let initialize = try #require(await readJSON(from: client))
        #expect(initialize["result"]?["serverInfo"]?["name"] == .string("tingra"))

        try await client.writeMessage(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8Data)
        let list = try #require(await readJSON(from: client))
        let names = list["result"]?["tools"].flatMap { value -> [String] in
            guard case .array(let entries) = value else { return [] }
            return entries.compactMap { $0["name"]?.stringValue }
        }
        #expect(names == ["devices_list"])

        try await client.writeMessage(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"devices_list"}}"#.utf8Data
        )
        let call = try #require(await readJSON(from: client))
        #expect(call["result"]?["isError"] == .bool(false))
        #expect(call["result"]?["structuredContent"]?["cameras"] == .array([]))

        // Clean shutdown: the daemon closes the connection (client read
        // returns nil) and the run loop returns.
        await daemon.shutdown()
        let closed = try? await client.readMessage()
        #expect(closed == nil)
        await client.close()
        await runTask.value
    }

    /// Reads the next message from a transport and decodes it into a
    /// ``JSONValue``, or nil at end of stream.
    private func readJSON(from transport: SocketMessageTransport) async -> JSONValue? {
        guard let data = try? await transport.readMessage() else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
