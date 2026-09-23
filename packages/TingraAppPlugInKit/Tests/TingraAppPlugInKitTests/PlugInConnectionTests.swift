//
//  PlugInConnectionTests.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import IOSurface
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

        /// The status items' texts by item id; an item of `undeclared` is
        /// answered with invalid params, the way the app answers an item
        /// the manifest does not declare.
        let statusTexts = Mutex<[String: String]>([:])

        /// Every request received, by method.
        let requests = Mutex<[String]>([])

        /// Whether this connection is subscribed to the meters.
        let isMeterSubscribed = Mutex(false)

        /// The buses a frame was demanded of, in order; a bus of `refused`
        /// cannot be spelled by the kit, so ``refusesFrames`` stands in.
        let frameDemands = Mutex<[String]>([])

        /// Whether a frame demand is answered with an error.
        let refusesFrames = Mutex(false)

        /// Whether a meters subscription is answered with an error.
        let refusesMeters = Mutex(false)

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
            case AppTierMethod.frameNext:
                if refusesFrames.withLock({ $0 }) {
                    return .failure(id: id, error: JSONRPCError(code: .invalidParams, message: "No such bus."))
                }
                frameDemands.withLock { $0.append(params?["bus"]?.stringValue ?? "") }
                return .success(id: id, result: .object([:]))
            case AppTierMethod.metersSubscribe:
                if refusesMeters.withLock({ $0 }) {
                    return .failure(id: id, error: JSONRPCError(code: .internalError, message: "No mixer."))
                }
                isMeterSubscribed.withLock { $0 = true }
                return .success(id: id, result: .object([:]))
            case AppTierMethod.metersUnsubscribe:
                isMeterSubscribed.withLock { $0 = false }
                return .success(id: id, result: .object([:]))
            case AppTierMethod.statusItemSet:
                let item = params?["item"]?.stringValue ?? ""
                guard item != "undeclared" else {
                    return .failure(
                        id: id,
                        error: JSONRPCError(code: .invalidParams, message: "No status item 'undeclared' is declared."))
                }
                statusTexts.withLock { $0[item] = params?["text"]?.stringValue }
                return .success(id: id, result: .object([:]))
            default:
                return .failure(id: id, error: JSONRPCError(code: .methodNotFound, message: "Unknown '\(method)'."))
            }
        }

        /// Sends the extension one frame, its surface beside the JSON.
        func sendFrame(_ frame: BusFrame) async throws {
            let notification = JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string(AppTierMethod.frame), "params": frame.jsonValue,
            ])
            let payload = try JSONEncoder().encode(notification)
            if let surface = frame.surface {
                try await transport.writeMessage(payload, surface: surface)
            } else {
                try await transport.writeMessage(payload)
            }
        }

        /// Sends the extension one window of meter levels.
        func sendMeters(_ levels: MeterLevels) async throws {
            let notification = JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string(AppTierMethod.meters), "params": levels.jsonValue,
            ])
            try await transport.writeMessage(try JSONEncoder().encode(notification))
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

    /// A small BGRA surface, the kind a program frame is backed by.
    private func makeSurface() throws -> IOSurface {
        try #require(
            IOSurface(properties: [.width: 16, .height: 9, .bytesPerElement: 4, .pixelFormat: 0x4247_5241]))
    }

    @Test("following a bus demands a frame, yields the app's own surface, and each arrival demands the next")
    func followsFrames() async throws {
        let (connection, app) = makePair()
        var iterator = connection.frames(.program).makeAsyncIterator()
        await eventually { app.frameDemands.withLock { $0 } == ["program"] }

        let surface = try makeSurface()
        try await app.sendFrame(BusFrame(bus: .program, surface: surface, time: 3.5))
        let frame = await iterator.next()
        #expect(frame?.surface === surface)
        #expect(frame?.bus == .program)
        #expect(frame?.time == 3.5)
        await eventually { app.frameDemands.withLock { $0.count } == 2 }

        // An emptied bus arrives as a frame without pixels.
        try await app.sendFrame(BusFrame(bus: .program, surface: nil, time: 0))
        let empty = await iterator.next()
        #expect(empty != nil)
        #expect(empty?.surface == nil)
        await connection.close()
    }

    @Test("a frame that arrives after the last follower stopped demands no other")
    func frameDemandLapses() async throws {
        let (connection, app) = makePair()
        let following = Task {
            for await _ in connection.frames(.preview) {}
        }
        await eventually { app.frameDemands.withLock { $0 } == ["preview"] }
        following.cancel()
        await following.value
        try await Task.sleep(for: .milliseconds(20))
        try await app.sendFrame(BusFrame(bus: .preview, surface: try makeSurface(), time: 1))
        try await Task.sleep(for: .milliseconds(30))
        #expect(app.frameDemands.withLock { $0 } == ["preview"])
        await connection.close()
    }

    @Test("a frame of another bus, or one claiming pixels it did not bring, reaches no follower")
    func strayFramesIgnored() async throws {
        let (connection, app) = makePair()
        var iterator = connection.frames(.program).makeAsyncIterator()
        await eventually { app.frameDemands.withLock { $0 } == ["program"] }
        try await app.sendFrame(BusFrame(bus: .preview, surface: try makeSurface(), time: 1))
        try await app.transport.writeMessage(
            Data(#"{"jsonrpc":"2.0","method":"tingra/frame","params":{"bus":"program","time":2,"empty":false}}"#.utf8))
        let surface = try makeSurface()
        try await app.sendFrame(BusFrame(bus: .program, surface: surface, time: 3))
        let frame = await iterator.next()
        #expect(frame?.time == 3)
        #expect(frame?.surface === surface)
        await connection.close()
    }

    @Test("a frame demand the app answers with an error ends the stream")
    func frameDemandRefused() async throws {
        let (connection, app) = makePair()
        app.refusesFrames.withLock { $0 = true }
        var iterator = connection.frames(.program).makeAsyncIterator()
        #expect(await iterator.next() == nil)
        await connection.close()
    }

    @Test("a frame's JSON names the bus, the time, and whether it is empty, and reads back with its surface")
    func frameJSON() throws {
        let surface = try makeSurface()
        let frame = BusFrame(bus: .preview, surface: surface, time: 9.25)
        #expect(
            frame.jsonValue == .object(["bus": .string("preview"), "time": .double(9.25), "empty": .bool(false)]))
        let read = try #require(BusFrame(jsonValue: frame.jsonValue, surface: surface))
        #expect(read.bus == .preview)
        #expect(read.time == 9.25)
        #expect(read.surface === surface)
        let empty = BusFrame(bus: .preview, surface: nil, time: 0)
        #expect(empty.jsonValue["empty"] == .bool(true))
        #expect(BusFrame(jsonValue: empty.jsonValue, surface: nil)?.surface == nil)
        // Marked empty yet carrying pixels, an unknown bus, no bus at all.
        #expect(BusFrame(jsonValue: empty.jsonValue, surface: surface) == nil)
        #expect(BusFrame(jsonValue: .object(["bus": "multiview"]), surface: surface) == nil)
        #expect(BusFrame(jsonValue: nil, surface: surface) == nil)
    }

    /// One window of levels: a hot microphone and a quieter master.
    private var levels: MeterLevels {
        MeterLevels(
            time: 12.5, strips: [InputID(rawValue: "mic"): MeterLevel(peak: 0.9, rms: 0.25)],
            masterLeft: MeterLevel(peak: 0.5, rms: 0.125), masterRight: .floor)
    }

    @Test("following the meters subscribes, yields each window's levels, and stopping unsubscribes")
    func followsMeters() async throws {
        let (connection, app) = makePair()
        var iterator = connection.meters().makeAsyncIterator()
        await eventually { app.isMeterSubscribed.withLock { $0 } }
        #expect(app.requests.withLock { $0 } == [AppTierMethod.metersSubscribe])

        try await app.sendMeters(levels)
        #expect(await iterator.next() == levels)

        let waiting = Task { await iterator.next() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        _ = await waiting.value
        await eventually { !app.isMeterSubscribed.withLock { $0 } }
        #expect(app.requests.withLock { $0 }.last == AppTierMethod.metersUnsubscribe)
        await connection.close()
    }

    @Test("two followers of the meters share one subscription, which ends with the last of them")
    func metersFollowersShareSubscription() async throws {
        let (connection, app) = makePair()
        var first = connection.meters().makeAsyncIterator()
        var second = connection.meters().makeAsyncIterator()
        await eventually { app.isMeterSubscribed.withLock { $0 } }
        try await Task.sleep(for: .milliseconds(20))
        try await app.sendMeters(levels)
        #expect(await first.next() == levels)
        #expect(await second.next() == levels)
        #expect(app.requests.withLock { $0 } == [AppTierMethod.metersSubscribe])

        let stopping = Task { await first.next() }
        try await Task.sleep(for: .milliseconds(20))
        stopping.cancel()
        _ = await stopping.value
        try await Task.sleep(for: .milliseconds(20))
        #expect(app.isMeterSubscribed.withLock { $0 })
        await connection.close()
    }

    @Test("a meters subscription the app answers with an error ends the stream")
    func metersSubscriptionRefused() async throws {
        let (connection, app) = makePair()
        app.refusesMeters.withLock { $0 = true }
        var iterator = connection.meters().makeAsyncIterator()
        #expect(await iterator.next() == nil)
        await connection.close()
    }

    @Test("a malformed meters notification is dropped and the next window still arrives")
    func malformedMetersDropped() async throws {
        let (connection, app) = makePair()
        var iterator = connection.meters().makeAsyncIterator()
        await eventually { app.isMeterSubscribed.withLock { $0 } }
        try await app.transport.writeMessage(
            Data(#"{"jsonrpc":"2.0","method":"tingra/meters","params":{"time":1}}"#.utf8))
        try await app.sendMeters(levels)
        #expect(await iterator.next() == levels)
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

    @Test("a status item takes a text, nil removes it, and an undeclared item throws the app's error")
    func setsStatusText() async throws {
        let (connection, app) = makePair()
        let link = StatusItemID(rawValue: "link")
        try await connection.setStatusText("Connected", for: link)
        #expect(app.statusTexts.withLock { $0["link"] } == "Connected")
        try await connection.setStatusText(nil, for: link)
        #expect(app.statusTexts.withLock { $0["link"] } == nil)
        do {
            try await connection.setStatusText("x", for: StatusItemID(rawValue: "undeclared"))
            Issue.record("an undeclared item should throw")
        } catch let error as PlugInConnectionError {
            guard case .protocolError(let protocolError) = error else {
                Issue.record("expected the app's protocol error, got \(error)")
                return
            }
            #expect(protocolError.code == JSONRPCErrorCode.invalidParams.rawValue)
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
