//
//  PlugInConnectionTests.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraJSONRPC
import TingraPlugInKit

@testable import TingraAppPlugInKit

/// The extension's connection to the app, run against a scripted app
/// endpoint over a linked in-memory transport pair: the handshake, tool
/// calls, events, storage, and the command the app forwards.
@Suite("Plug-in connection")
struct PlugInConnectionTests {
    /// A scripted stand-in for the app's endpoint: answers each request by
    /// method, records notifications, and can send a request of its own.
    private final class FakeApp: Sendable {
        /// The app's side of the pair.
        let transport: InMemoryMessageTransport

        /// Every notification received, by method, with params.
        let notifications = Mutex<[(method: String, params: JSONValue?)]>([])

        /// The stored values by scope.
        let storage = Mutex<[String: JSONValue]>([:])

        /// Every request received, by method.
        let requests = Mutex<[String]>([])

        /// Responses to the app's own requests, by id.
        let answers = AsyncQueue<JSONValue>()

        /// Whether `tools/list` is answered with a method-not-found error.
        let rejectsToolsList = Mutex(false)

        /// The serving task.
        private let task = Mutex<Task<Void, Never>?>(nil)

        /// Starts serving on `transport`.
        init(transport: InMemoryMessageTransport) {
            self.transport = transport
            let serving = Task { await self.serve() }
            task.withLock { $0 = serving }
        }

        /// Reads until the pair closes, answering what it understands.
        private func serve() async {
            while let payload = try? await transport.readMessage() {
                guard let incoming = try? MessageCoder.decode(payload) else { continue }
                if incoming.method == nil, let id = incoming.id {
                    // A response to the app's own request.
                    let object = (try? JSONDecoder().decode(JSONValue.self, from: payload)) ?? .null
                    _ = id
                    answers.enqueue(object)
                    continue
                }
                guard let method = incoming.method else { continue }
                guard let id = incoming.id else {
                    notifications.withLock { $0.append((method, incoming.params)) }
                    continue
                }
                requests.withLock { $0.append(method) }
                let response = respond(id: id, method: method, params: incoming.params)
                if let data = try? MessageCoder.encode(response) { try? await transport.writeMessage(data) }
            }
        }

        /// The scripted answers.
        private func respond(id: JSONRPCID, method: String, params: JSONValue?) -> JSONRPCResponse {
            switch method {
            case "initialize":
                return .success(id: id, result: .object(["serverInfo": .object(["name": .string("Tingra")])]))
            case "tools/list":
                if rejectsToolsList.withLock({ $0 }) {
                    return .failure(
                        id: id, error: JSONRPCError(code: .methodNotFound, message: "Unknown 'tools/list'."))
                }
                return .success(id: id, result: .object(["tools": .array([.object(["name": .string("shot_take")])])]))
            case "tools/call":
                if params?["name"]?.stringValue == "broken" {
                    return .success(
                        id: id,
                        result: .object([
                            "isError": .bool(true),
                            "structuredContent": .object([
                                "identifier": .string("invalid_argument"), "message": .string("No such shot."),
                            ]),
                        ]))
                }
                return .success(
                    id: id,
                    result: .object([
                        "isError": .bool(false),
                        "structuredContent": .object(["took": params?["arguments"]?["shot"] ?? .null]),
                    ]))
            case AppTierMethod.storageGet:
                let scope = params?["scope"]?.stringValue ?? ""
                return .success(id: id, result: .object(["value": storage.withLock { $0[scope] } ?? .null]))
            case AppTierMethod.storageSet:
                let scope = params?["scope"]?.stringValue ?? ""
                storage.withLock { $0[scope] = params?["value"] }
                return .success(id: id, result: .object([:]))
            default:
                return .failure(id: id, error: JSONRPCError(code: .methodNotFound, message: "Unknown '\(method)'."))
            }
        }

        /// Sends the app's one request: perform a command.
        func perform(_ command: String, id: Int = 100) async throws {
            let payload = Data(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"tingra/command.perform","params":{"command":"\#(command)"}}"#
                    .utf8)
            try await transport.writeMessage(payload)
        }
    }

    /// A connection and its scripted app.
    private func makePair(
        performCommand: @escaping PlugInConnection.CommandHandler = { _, _ in }
    ) -> (PlugInConnection, FakeApp) {
        let (extensionSide, appSide) = LinkedMessageTransports.makePair()
        let app = FakeApp(transport: appSide)
        let connection = PlugInConnection(
            transport: extensionSide, clientName: "com.moonwink.tingra.notes", clientVersion: "1.0",
            performCommand: performCommand)
        return (connection, app)
    }

    @Test("initialize sends the handshake and the initialized notification")
    func initializes() async throws {
        let (connection, app) = makePair()
        let result = try await connection.initialize()
        #expect(result["serverInfo"]?["name"]?.stringValue == "Tingra")
        #expect(app.requests.withLock { $0 } == ["initialize"])
        // The notification is one-way; the app's loop reads it a moment later.
        await eventually { app.notifications.withLock { $0.map(\.method) } == ["notifications/initialized"] }
        #expect(app.notifications.withLock { $0.map(\.method) } == ["notifications/initialized"])
        await connection.close()
    }

    @Test("a tool call returns the structured content")
    func callsTool() async throws {
        let (connection, _) = makePair()
        let result = try await connection.call("shot_take", arguments: .object(["shot": .string("bars")]))
        #expect(result["took"]?.stringValue == "bars")
        await connection.close()
    }

    @Test("a tool that reports an error throws it with its identifier")
    func toolErrorThrows() async throws {
        let (connection, _) = makePair()
        await #expect(throws: PlugInConnectionError.tool(identifier: "invalid_argument", message: "No such shot.")) {
            try await connection.call("broken")
        }
        await connection.close()
    }

    @Test("a JSON-RPC error from the app is thrown as a protocol error")
    func protocolErrorThrows() async throws {
        let (connection, app) = makePair()
        app.rejectsToolsList.withLock { $0 = true }
        await #expect(
            throws: PlugInConnectionError.protocolError(
                JSONRPCError(code: .methodNotFound, message: "Unknown 'tools/list'."))
        ) {
            _ = try await connection.tools()
        }
        await connection.close()
    }

    @Test("tools/list returns the descriptors")
    func listsTools() async throws {
        let (connection, _) = makePair()
        let tools = try await connection.tools()
        #expect(tools.first?["name"]?.stringValue == "shot_take")
        await connection.close()
    }

    @Test("an event lands as a tingra/event notification carrying name, group, and params")
    func sendsEvent() async throws {
        let (connection, app) = makePair()
        await connection.event("notes.edited", params: ["characters": .int(12)])
        await connection.error("notes.broken")
        // Notifications are one-way; the app's loop reads them a moment later.
        await eventually { app.notifications.withLock { $0.count } == 2 }
        let received = app.notifications.withLock { $0 }
        #expect(received.count == 2)
        #expect(received.first?.params?["name"]?.stringValue == "notes.edited")
        #expect(received.first?.params?["group"]?.stringValue == "event")
        #expect(received.first?.params?["params"]?["characters"]?.intValue == 12)
        #expect(received.last?.params?["group"]?.stringValue == "error")
        #expect(received.last?.params?["params"] == nil)
        await connection.close()
    }

    @Test("project and application storage round-trip, and nil clears")
    func storesValues() async throws {
        let (connection, app) = makePair()
        let before = try await connection.projectData()
        #expect(before == nil)
        try await connection.setProjectData(.object(["text": .string("hello")]))
        let project = try await connection.projectData()
        #expect(project?["text"]?.stringValue == "hello")
        try await connection.setApplicationData(.int(14))
        let application = try await connection.applicationData()
        #expect(application == .int(14))
        #expect(app.storage.withLock { $0["project"] }?["text"]?.stringValue == "hello")
        try await connection.setProjectData(nil)
        let cleared = try await connection.projectData()
        #expect(cleared == nil)
        await connection.close()
    }

    @Test("a command the app forwards runs the handler and is answered")
    func performsCommand() async throws {
        let performed = Mutex<[String]>([])
        let (connection, app) = makePair { command, _ in
            performed.withLock { $0.append(command.rawValue) }
        }
        try await app.perform("show")
        let answer = await app.answers.next()
        #expect(answer?["id"]?.intValue == 100)
        #expect(answer?["result"] == .object([:]))
        #expect(performed.withLock { $0 } == ["show"])
        await connection.close()
    }

    @Test("a command handler that throws answers with an internal error")
    func performThrowsAnswersError() async throws {
        let (connection, app) = makePair { _, _ in throw PlugInConnectionError.unexpectedMessage }
        try await app.perform("show", id: 7)
        let answer = await app.answers.next()
        #expect(answer?["id"]?.intValue == 7)
        #expect(answer?["error"]?["code"]?.intValue == JSONRPCErrorCode.internalError.rawValue)
        await connection.close()
    }

    @Test("closing the connection ends a pending request as closed")
    func closeEndsPending() async throws {
        let (extensionSide, _) = LinkedMessageTransports.makePair()
        // No app on the other side: the request never gets an answer.
        let connection = PlugInConnection(
            transport: extensionSide, clientName: "c", clientVersion: "1", performCommand: { _, _ in })
        let waiting = Task { try await connection.tools() }
        try await Task.sleep(for: .milliseconds(20))
        await connection.close()
        await #expect(throws: PlugInConnectionError.closed) { try await waiting.value }
    }
}

/// Waits, in short steps up to a second, for `condition` to hold — for the
/// one-way notifications the fake app reads on its own loop.
private func eventually(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
