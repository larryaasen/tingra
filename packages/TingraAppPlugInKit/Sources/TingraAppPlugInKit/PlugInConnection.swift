//
//  PlugInConnection.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraJSONRPC
import TingraPlugInKit

/// The extension's end of one connection to the app: an MCP client over a
/// ``MessageTransport`` that calls the app's tools, reads and follows the
/// app's resources, files events on the app's bus, reads and writes the
/// plug-in's storage, and answers the one request the app makes of it, a
/// command to perform (PLUGINS.md, Phase 1, "`PlugInConnection`"; Phase 2,
/// "seams into the engine").
///
/// One instance per `NSXPCConnection` the app opens — one for each hosted
/// pane and one for commands — all in the one extension process. The kit
/// creates them (``PlugInRuntime``); an author receives them.
public actor PlugInConnection {
    /// Performs a command the app forwarded. Main-actor isolated, so an
    /// extension — a main-actor type by `AppExtension`'s requirements — can
    /// be the one performing it without the conformance itself having to
    /// be sendable.
    public typealias CommandHandler = @MainActor @Sendable (CommandID, PlugInConnection) async throws -> Void

    /// The transport to the app.
    private let transport: any MessageTransport

    /// Performs commands the app forwards.
    private let performCommand: CommandHandler

    /// The MCP client identity sent in `initialize`.
    private let client: (name: String, version: String)

    /// The next request id.
    private var nextID = 1

    /// Requests awaiting a response, by id.
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]

    /// The read loop, while running.
    private var readTask: Task<Void, Never>?

    /// Whether the transport has ended.
    private var isClosed = false

    /// The change signals of the resources being followed (``observe(_:)``),
    /// by URI and then by follower: an updated notification for a URI
    /// wakes every follower of it.
    private var resourceSignals: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

    /// Creates a connection over `transport` and starts reading.
    ///
    /// - Parameters:
    ///   - transport: The channel to the app.
    ///   - clientName: The plug-in id, reported to the app in `initialize`.
    ///   - clientVersion: The plug-in's version, likewise.
    ///   - performCommand: Performs commands the app forwards.
    public init(
        transport: any MessageTransport, clientName: String, clientVersion: String,
        performCommand: @escaping CommandHandler
    ) {
        self.transport = transport
        self.client = (clientName, clientVersion)
        self.performCommand = performCommand
        Task { await self.startReading() }
    }

    /// Runs the MCP handshake: `initialize`, then the `initialized`
    /// notification.
    ///
    /// - Returns: The app's `initialize` result (its server info and
    ///   capabilities).
    /// - Throws: ``PlugInConnectionError``.
    @discardableResult
    public func initialize() async throws -> JSONValue {
        let result = try await request(
            "initialize",
            params: .object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string(client.name), "version": .string(client.version)]),
            ]))
        try await notify("notifications/initialized", params: nil)
        return result
    }

    /// Calls one of the app's tools (`tools/call`, PLUGINS.md Decision 10).
    ///
    /// - Parameters:
    ///   - tool: The tool's name (`shot_take`).
    ///   - arguments: The tool's arguments.
    /// - Returns: The tool's structured result.
    /// - Throws: ``PlugInConnectionError/tool(identifier:message:)`` when the
    ///   tool reports an error, or another ``PlugInConnectionError``.
    public func call(_ tool: String, arguments: JSONValue = .object([:])) async throws -> JSONValue {
        let result = try await request("tools/call", params: .object(["name": .string(tool), "arguments": arguments]))
        if result["isError"]?.boolValue == true {
            let structured = result["structuredContent"]
            throw PlugInConnectionError.tool(
                identifier: structured?["identifier"]?.stringValue ?? "unknown",
                message: structured?["message"]?.stringValue ?? "The tool reported an error.")
        }
        return result["structuredContent"] ?? result
    }

    /// Lists the app's tools (`tools/list`).
    ///
    /// - Returns: The tool descriptors.
    /// - Throws: ``PlugInConnectionError``.
    public func tools() async throws -> [JSONValue] {
        try await request("tools/list", params: nil)["tools"]?.arrayValue ?? []
    }

    /// Lists the app's resources (`resources/list`): what the plug-in can
    /// observe of the engine — `tingra://session`, `tingra://program`,
    /// `tingra://inputs` (PLUGINS.md, Phase 2).
    ///
    /// - Returns: The resource descriptors (`uri`, `name`, `title`,
    ///   `description`, `mimeType`).
    /// - Throws: ``PlugInConnectionError``.
    public func resources() async throws -> [JSONValue] {
        try await request("resources/list", params: nil)["resources"]?.arrayValue ?? []
    }

    /// Reads a resource's current contents (`resources/read`), decoded
    /// from its JSON text.
    ///
    /// - Parameter uri: The resource's URI (`tingra://program`).
    /// - Returns: The document.
    /// - Throws: ``PlugInConnectionError/protocolError(_:)`` for a URI the
    ///   app has no resource at, ``PlugInConnectionError/unexpectedMessage``
    ///   for contents that are not JSON text, or another
    ///   ``PlugInConnectionError``.
    public func read(_ uri: String) async throws -> JSONValue {
        let result = try await request("resources/read", params: .object(["uri": .string(uri)]))
        guard let text = result["contents"]?.arrayValue?.first?["text"]?.stringValue,
            let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { throw PlugInConnectionError.unexpectedMessage }
        return value
    }

    /// Follows a resource: the stream yields its contents now and again
    /// after every change the app reports, until the consumer stops
    /// iterating, which ends the subscription. A pane showing what is on
    /// program iterates this in a `.task`; nothing polls.
    ///
    /// Changes coalesce — a burst arrives as one re-read — and a read that
    /// cannot be made (the connection closed) ends the stream.
    ///
    /// - Parameter uri: The resource's URI.
    /// - Returns: The contents, now and after each change.
    public nonisolated func observe(_ uri: String) -> AsyncStream<JSONValue> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { await self.follow(uri, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Files an event on the app's bus under the plug-in's domain — the
    /// plug-in's logging, reaching the log file, OSLog, and the log window
    /// through the app's sinks (PLUGINS.md, "Logging needs no new seam").
    ///
    /// - Parameters:
    ///   - name: The event name (`notes.edited`).
    ///   - params: The event's params.
    public func event(_ name: String, params: [String: JSONValue] = [:]) async {
        await sendEvent(name, params: params, group: "event")
    }

    /// Files an error event on the app's bus under the plug-in's domain.
    ///
    /// - Parameters:
    ///   - name: The event name.
    ///   - params: The event's params.
    public func error(_ name: String, params: [String: JSONValue] = [:]) async {
        await sendEvent(name, params: params, group: "error")
    }

    /// The plug-in's project-scoped value, or nil when nothing is stored
    /// in the open project.
    ///
    /// - Throws: ``PlugInConnectionError``.
    public func projectData() async throws -> JSONValue? {
        try await storedValue(scope: .project)
    }

    /// Replaces the plug-in's project-scoped value; nil clears it. The
    /// project is dirtied like any edit and the value saves with it.
    ///
    /// - Parameter value: The value to store.
    /// - Throws: ``PlugInConnectionError``.
    public func setProjectData(_ value: JSONValue?) async throws {
        try await store(value, scope: .project)
    }

    /// The plug-in's app-scoped value on this Mac, or nil when nothing is
    /// stored.
    ///
    /// - Throws: ``PlugInConnectionError``.
    public func applicationData() async throws -> JSONValue? {
        try await storedValue(scope: .application)
    }

    /// Replaces the plug-in's app-scoped value; nil clears it.
    ///
    /// - Parameter value: The value to store.
    /// - Throws: ``PlugInConnectionError``.
    public func setApplicationData(_ value: JSONValue?) async throws {
        try await store(value, scope: .application)
    }

    /// Closes the connection; pending requests end with
    /// ``PlugInConnectionError/closed``.
    public func close() async {
        readTask?.cancel()
        await transport.close()
        endPending()
    }

    // MARK: - Resources

    /// The body of ``observe(_:)``: subscribes, reads once, then reads
    /// again on each updated notification until cancelled or the connection
    /// ends, and unsubscribes on the way out.
    private func follow(_ uri: String, into continuation: AsyncStream<JSONValue>.Continuation) async {
        let follower = UUID()
        let signals = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { signal in
            resourceSignals[uri, default: [:]][follower] = signal
        }
        defer {
            resourceSignals[uri]?[follower] = nil
            continuation.finish()
        }
        do {
            _ = try await request("resources/subscribe", params: .object(["uri": .string(uri)]))
            continuation.yield(try await read(uri))
        } catch {
            return
        }
        for await _ in signals {
            guard !Task.isCancelled, let value = try? await read(uri) else { break }
            continuation.yield(value)
        }
        _ = try? await request("resources/unsubscribe", params: .object(["uri": .string(uri)]))
    }

    /// Wakes every follower of `uri`: the app said it changed.
    private func resourceUpdated(_ uri: String) {
        guard let followers = resourceSignals[uri] else { return }
        for signal in followers.values {
            signal.yield(())
        }
    }

    // MARK: - Wire

    /// Sends a request and awaits its result.
    private func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        guard !isClosed else { throw PlugInConnectionError.closed }
        let id = nextID
        nextID += 1
        let payload = try MessageCoder.encode(OutgoingRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.writeMessage(payload)
                } catch {
                    self.settle(id, with: .failure(PlugInConnectionError.transport(String(describing: error))))
                }
            }
        }
    }

    /// Sends a notification.
    private func notify(_ method: String, params: JSONValue?) async throws {
        guard !isClosed else { throw PlugInConnectionError.closed }
        let payload = try MessageCoder.encode(JSONRPCNotification(method: method, params: params))
        do {
            try await transport.writeMessage(payload)
        } catch {
            throw PlugInConnectionError.transport(String(describing: error))
        }
    }

    /// Sends a `tingra/event` notification, swallowing transport errors: a
    /// log line must never take the plug-in down.
    private func sendEvent(_ name: String, params: [String: JSONValue], group: String) async {
        var body: [String: JSONValue] = [
            AppTierMethod.EventParam.name: .string(name), AppTierMethod.EventParam.group: .string(group),
        ]
        if !params.isEmpty { body[AppTierMethod.EventParam.params] = .object(params) }
        try? await notify(AppTierMethod.event, params: .object(body))
    }

    /// Reads a stored value.
    private func storedValue(scope: StorageScope) async throws -> JSONValue? {
        let result = try await request(
            AppTierMethod.storageGet, params: .object([AppTierMethod.StorageParam.scope: .string(scope.rawValue)]))
        guard let value = result[AppTierMethod.StorageParam.value], value != .null else { return nil }
        return value
    }

    /// Writes a stored value.
    private func store(_ value: JSONValue?, scope: StorageScope) async throws {
        _ = try await request(
            AppTierMethod.storageSet,
            params: .object([
                AppTierMethod.StorageParam.scope: .string(scope.rawValue),
                AppTierMethod.StorageParam.value: value ?? .null,
            ]))
    }

    /// Starts the read loop.
    private func startReading() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let payload: Data?
                do {
                    payload = try await self.transport.readMessage()
                } catch {
                    break
                }
                guard let payload else { break }
                await self.handle(payload)
            }
            await self?.endPending()
        }
    }

    /// Routes one incoming message: a response settles its request, a
    /// request is answered, a resource-updated notification wakes the
    /// resource's followers, and any other notification is ignored.
    private func handle(_ payload: Data) async {
        guard let incoming = try? MessageCoder.decode(payload) else { return }
        switch (incoming.id, incoming.method) {
        case (.some(let id), .none):
            guard case .number(let number) = id else { return }
            settle(number, with: responseResult(payload))
        case (.some(let id), .some(let method)):
            let response = await respond(id: id, method: method, params: incoming.params)
            if let data = try? MessageCoder.encode(response) {
                try? await transport.writeMessage(data)
            }
        case (.none, .some("notifications/resources/updated")):
            if let uri = incoming.params?["uri"]?.stringValue { resourceUpdated(uri) }
        case (.none, _):
            break
        }
    }

    /// The result or error of a response payload.
    private func responseResult(_ payload: Data) -> Result<JSONValue, any Error> {
        guard let response = try? JSONDecoder().decode(IncomingResponse.self, from: payload) else {
            return .failure(PlugInConnectionError.unexpectedMessage)
        }
        if let error = response.error { return .failure(PlugInConnectionError.protocolError(error)) }
        return .success(response.result ?? .null)
    }

    /// Answers a request from the app.
    private func respond(id: JSONRPCID, method: String, params: JSONValue?) async -> JSONRPCResponse {
        switch method {
        case AppTierMethod.commandPerform:
            guard let command = params?[AppTierMethod.CommandParam.command]?.stringValue else {
                return .failure(
                    id: id, error: JSONRPCError(code: .invalidParams, message: "A command.perform needs a 'command'."))
            }
            do {
                try await performCommand(CommandID(rawValue: command), self)
                return .success(id: id, result: .object([:]))
            } catch {
                return .failure(
                    id: id, error: JSONRPCError(code: .internalError, message: String(describing: error)))
            }
        case "ping":
            return .success(id: id, result: .object([:]))
        default:
            return .failure(id: id, error: JSONRPCError(code: .methodNotFound, message: "Unknown method '\(method)'."))
        }
    }

    /// Resumes the request `id` with `result`.
    private func settle(_ id: Int, with result: Result<JSONValue, any Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    /// Ends every pending request as closed, and every followed resource's
    /// signals with it.
    private func endPending() {
        isClosed = true
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: PlugInConnectionError.closed)
        }
        let followers = resourceSignals
        resourceSignals = [:]
        for signal in followers.values.flatMap(\.values) {
            signal.finish()
        }
    }

    /// A request the extension sends.
    private struct OutgoingRequest: Encodable {
        /// The protocol version tag.
        let jsonrpc = "2.0"

        /// The request id.
        let id: Int

        /// The method.
        let method: String

        /// The params, if any.
        let params: JSONValue?

        /// The stable keys.
        private enum CodingKeys: String, CodingKey {
            case jsonrpc
            case id
            case method
            case params
        }
    }

    /// A response the app sends.
    private struct IncomingResponse: Decodable {
        /// The result, on success.
        let result: JSONValue?

        /// The error, on a protocol failure.
        let error: JSONRPCError?
    }
}

/// What a ``PlugInConnection`` call can get wrong.
public enum PlugInConnectionError: Error, Equatable, CustomStringConvertible {
    /// The connection is closed; the app or the process went away.
    case closed

    /// The transport reported an error.
    case transport(String)

    /// The app answered with a JSON-RPC error.
    case protocolError(JSONRPCError)

    /// The tool ran and reported an error, keyed by Tingra's error
    /// identifier registry.
    case tool(identifier: String, message: String)

    /// A response did not decode.
    case unexpectedMessage

    public var description: String {
        switch self {
        case .closed: "The connection to Tingra is closed."
        case .transport(let detail): "The connection to Tingra reported an error: \(detail)"
        case .protocolError(let error): "Tingra answered with JSON-RPC error \(error.code): \(error.message)"
        case .tool(let identifier, let message): "The tool reported '\(identifier)': \(message)"
        case .unexpectedMessage: "Tingra sent a response that does not decode."
        }
    }
}
