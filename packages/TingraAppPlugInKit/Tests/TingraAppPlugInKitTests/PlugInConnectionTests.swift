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
import TingraEventBus
import TingraJSONRPC
import TingraPlugInKit

@testable import TingraAppPlugInKit

/// The extension's connection to the app, run against a scripted app
/// endpoint over a linked in-memory transport pair: the handshake, tool
/// calls, events, storage, the command the app forwards, and the
/// activation the app reports.
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

        /// The stored secrets by name; a name of `refused` is answered with
        /// an internal error, the way a Keychain that rejects the binary
        /// is.
        let secrets = Mutex<[String: String]>([:])

        /// Every request received, by method.
        let requests = Mutex<[String]>([])

        /// Responses to the app's own requests, by id.
        let answers = AsyncQueue<JSONValue>()

        /// Whether `tools/list` is answered with a method-not-found error.
        let rejectsToolsList = Mutex(false)

        /// The document `tingra://program` reads as.
        let program = Mutex<JSONValue>(.object(["programShot": .string("wide")]))

        /// The URIs subscribed to and not yet unsubscribed from, in order.
        let subscriptions = Mutex<[String]>([])

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
            case "resources/list":
                return .success(
                    id: id,
                    result: .object([
                        "resources": .array([
                            .object(["uri": .string("tingra://program"), "name": .string("program")])
                        ])
                    ]))
            case "resources/read", "resources/subscribe", "resources/unsubscribe":
                guard params?["uri"]?.stringValue == "tingra://program" else {
                    return .failure(
                        id: id, error: JSONRPCError(code: .resourceNotFound, message: "No resource there."))
                }
                if method == "resources/subscribe" { subscriptions.withLock { $0.append("tingra://program") } }
                if method == "resources/unsubscribe" {
                    subscriptions.withLock { $0.removeAll { $0 == "tingra://program" } }
                }
                guard method == "resources/read" else { return .success(id: id, result: .object([:])) }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let text = (try? encoder.encode(program.withLock { $0 })).map { String(decoding: $0, as: UTF8.self) }
                return .success(
                    id: id,
                    result: .object([
                        "contents": .array([
                            .object([
                                "uri": .string("tingra://program"), "mimeType": .string("application/json"),
                                "text": .string(text ?? "{}"),
                            ])
                        ])
                    ]))
            case AppTierMethod.storageGet:
                let scope = params?["scope"]?.stringValue ?? ""
                return .success(id: id, result: .object(["value": storage.withLock { $0[scope] } ?? .null]))
            case AppTierMethod.storageSet:
                let scope = params?["scope"]?.stringValue ?? ""
                storage.withLock { $0[scope] = params?["value"] }
                return .success(id: id, result: .object([:]))
            case AppTierMethod.secretsGet, AppTierMethod.secretsSet:
                let name = params?["name"]?.stringValue ?? ""
                guard name != "refused" else {
                    return .failure(
                        id: id,
                        error: JSONRPCError(
                            code: .internalError, message: "The secure store rejected the operation (OSStatus -34018)."
                        ))
                }
                if method == AppTierMethod.secretsGet {
                    let value = secrets.withLock { $0[name] }.map(JSONValue.string) ?? .null
                    return .success(id: id, result: .object(["value": value]))
                }
                secrets.withLock { $0[name] = params?["value"]?.stringValue }
                return .success(id: id, result: .object([:]))
            default:
                return .failure(id: id, error: JSONRPCError(code: .methodNotFound, message: "Unknown '\(method)'."))
            }
        }

        /// Tells the extension a resource changed.
        func notifyUpdated(_ uri: String) async throws {
            let payload = Data(
                #"{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"\#(uri)"}}"#.utf8)
            try await transport.writeMessage(payload)
        }

        /// Sends the app's one request: perform a command.
        func perform(_ command: String, id: Int = 100) async throws {
            let payload = Data(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"tingra/command.perform","params":{"command":"\#(command)"}}"#
                    .utf8)
            try await transport.writeMessage(payload)
        }

        /// Sends the app's other request: an activation condition was met,
        /// with the event that met it as the app encodes one.
        func activate(_ condition: String, event: EventBusEvent?, id: Int = 200) async throws {
            var params: [String: JSONValue] = ["condition": .string(condition)]
            if let event {
                params["event"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
            }
            let request = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .int(id), "method": .string(AppTierMethod.activation),
                "params": .object(params),
            ])
            try await transport.writeMessage(try JSONEncoder().encode(request))
        }
    }

    /// A connection and its scripted app.
    private func makePair(
        performCommand: @escaping PlugInConnection.CommandHandler = { _, _ in },
        performActivation: @escaping PlugInConnection.ActivationHandler = { _, _, _ in }
    ) -> (PlugInConnection, FakeApp) {
        let (extensionSide, appSide) = LinkedMessageTransports.makePair()
        let app = FakeApp(transport: appSide)
        let connection = PlugInConnection(
            transport: extensionSide, clientName: "com.moonwink.tingra.notes", clientVersion: "1.0",
            performCommand: performCommand, performActivation: performActivation)
        return (connection, app)
    }

    /// The event that woke a plug-in, as the app would drain it from the bus.
    private var cameraConnected: EventBusEvent {
        EventBusEvent(
            date: Date(timeIntervalSinceReferenceDate: 800_000_000), group: .event, domain: .capture,
            name: "device.connected", params: ["kind": .string("camera"), "name": .string("FaceTime HD")],
            from: "DeviceChange.swift:report")
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

    @Test("resources/list returns the descriptors")
    func listsResources() async throws {
        let (connection, _) = makePair()
        let resources = try await connection.resources()
        #expect(resources.first?["uri"]?.stringValue == "tingra://program")
        await connection.close()
    }

    @Test("a resource read decodes the document from its JSON text")
    func readsResource() async throws {
        let (connection, _) = makePair()
        let program = try await connection.read("tingra://program")
        #expect(program["programShot"]?.stringValue == "wide")
        await connection.close()
    }

    @Test("a read of a URI the app has no resource at throws the protocol error")
    func readUnknownThrows() async throws {
        let (connection, _) = makePair()
        await #expect(
            throws: PlugInConnectionError.protocolError(
                JSONRPCError(code: .resourceNotFound, message: "No resource there."))
        ) {
            _ = try await connection.read("tingra://nothing")
        }
        await connection.close()
    }

    @Test("observing a resource yields it now and after each update, and stopping unsubscribes")
    func observesResource() async throws {
        let (connection, app) = makePair()
        var iterator = await connection.observe("tingra://program").makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?["programShot"]?.stringValue == "wide")
        #expect(app.subscriptions.withLock { $0 } == ["tingra://program"])

        app.program.withLock { $0 = .object(["programShot": .string("close")]) }
        try await app.notifyUpdated("tingra://program")
        let second = await iterator.next()
        #expect(second?["programShot"]?.stringValue == "close")

        // A notification for another resource wakes nobody.
        try await app.notifyUpdated("tingra://session")
        let waiting = Task { await iterator.next() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(app.requests.withLock { $0.filter { $0 == "resources/read" }.count } == 2)
        waiting.cancel()
        _ = await waiting.value
        await eventually { app.subscriptions.withLock { $0.isEmpty } }
        #expect(app.subscriptions.withLock { $0.isEmpty })
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

    @Test("a secret round-trips by name, nil removes it, and a refused store throws the app's error")
    func storesSecrets() async throws {
        let (connection, app) = makePair()
        let before = try await connection.secret(named: "token")
        #expect(before == nil)
        try await connection.setSecret("live_abc", named: "token")
        let stored = try await connection.secret(named: "token")
        #expect(stored == "live_abc")
        #expect(app.secrets.withLock { $0["token"] } == "live_abc")
        #expect(app.requests.withLock { $0 }.contains(AppTierMethod.secretsSet))
        try await connection.setSecret(nil, named: "token")
        let removed = try await connection.secret(named: "token")
        #expect(removed == nil)
        #expect(app.secrets.withLock { $0["token"] } == nil)
        await #expect(throws: PlugInConnectionError.self) {
            try await connection.setSecret("x", named: "refused")
        }
        do {
            _ = try await connection.secret(named: "refused")
            Issue.record("a refused read should throw")
        } catch let error as PlugInConnectionError {
            guard case .protocolError(let protocolError) = error else {
                Issue.record("expected the app's protocol error, got \(error)")
                return
            }
            #expect(protocolError.code == JSONRPCErrorCode.internalError.rawValue)
            #expect(protocolError.message.contains("-34018"))
        }
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

    @Test("an activation the app reports runs the handler with the condition and the event")
    func performsActivation() async throws {
        let received = Mutex<[(ActivationCondition, EventBusEvent)]>([])
        let (connection, app) = makePair(performActivation: { condition, event, _ in
            received.withLock { $0.append((condition, event)) }
        })
        try await app.activate("device.connected:kind=camera", event: cameraConnected)
        let answer = await app.answers.next()
        #expect(answer?["id"]?.intValue == 200)
        #expect(answer?["result"] == .object([:]))
        let (condition, event) = try #require(received.withLock { $0.first })
        let expected = try ActivationCondition(parsing: "device.connected:kind=camera")
        #expect(condition == expected)
        #expect(event == cameraConnected)
        await connection.close()
    }

    @Test("an activation handler that throws answers with an internal error")
    func activationThrowsAnswersError() async throws {
        let (connection, app) = makePair(performActivation: { _, _, _ in throw PlugInConnectionError.unexpectedMessage }
        )
        try await app.activate("stream.started", event: cameraConnected, id: 9)
        let answer = await app.answers.next()
        #expect(answer?["id"]?.intValue == 9)
        #expect(answer?["error"]?["code"]?.intValue == JSONRPCErrorCode.internalError.rawValue)
        await connection.close()
    }

    @Test("an activation without its event or with a malformed condition is invalid params")
    func activationWithoutEventIsInvalid() async throws {
        let handled = Mutex(0)
        let (connection, app) = makePair(performActivation: { _, _, _ in handled.withLock { $0 += 1 } })
        try await app.activate("stream.started", event: nil, id: 10)
        let missing = await app.answers.next()
        #expect(missing?["id"]?.intValue == 10)
        #expect(missing?["error"]?["code"]?.intValue == JSONRPCErrorCode.invalidParams.rawValue)
        try await app.activate("stream started", event: cameraConnected, id: 11)
        let malformed = await app.answers.next()
        #expect(malformed?["error"]?["code"]?.intValue == JSONRPCErrorCode.invalidParams.rawValue)
        #expect(handled.withLock { $0 } == 0)
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
