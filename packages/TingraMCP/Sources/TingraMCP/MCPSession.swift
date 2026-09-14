//
//  MCPSession.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// One MCP session: the JSON-RPC conversation over a single accepted
/// connection (GLOSSARY.md, "Session" — an MCP session is per connection,
/// distinct from the engine's one live session). Each connection gets its
/// own `initialize` handshake; all sessions are views onto the same engine
/// (MCP.md, "Sessions and concurrency").
///
/// The session reads framed messages, dispatches `initialize`, `ping`,
/// `tools/list`, and `tools/call` against the shared ``ToolRegistry``, and —
/// once initialized — forwards status changes from the ``StatusSink`` as
/// `notifications/message`. It never blocks the engine and never polls.
public actor MCPSession {
    /// The message channel for this connection.
    private let transport: any MessageTransport

    /// Answers the methods beyond MCP's own that this endpoint serves — the
    /// app tier's `tingra/*` storage and event methods (PLUGINS.md, Decision
    /// 14) — or nil for the daemon, which serves MCP alone.
    private let methods: (any SessionMethodHandler)?

    /// Requests this side sent and is awaiting responses to, by id. The
    /// daemon sends none; the app sends `tingra/command.perform`.
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]

    /// The next outgoing request id's number.
    private var nextRequestNumber = 1

    /// The shared tool registry every session lists and dispatches against.
    private let tools: ToolRegistry

    /// The status sink this session forwards as notifications.
    private let status: StatusSink

    /// The daemon identity reported in the `initialize` result.
    private let info: DaemonInfo

    /// The event bus, for the session's own lifecycle events (control domain).
    private let eventBus: EventBus

    /// Whether `initialize` has completed; `tools/*` require it.
    private var initialized = false

    /// The task forwarding status changes as notifications, started once the
    /// handshake completes and cancelled at teardown.
    private var notifierTask: Task<Void, Never>?

    /// Creates a session over a transport.
    ///
    /// - Parameters:
    ///   - transport: The message channel for the connection.
    ///   - tools: The shared tool registry.
    ///   - status: The status sink to forward as notifications.
    ///   - info: The daemon identity for the handshake.
    ///   - eventBus: The event bus for lifecycle events.
    ///   - methods: Answers the endpoint's own methods beyond MCP, or nil.
    public init(
        transport: any MessageTransport,
        tools: ToolRegistry,
        status: StatusSink,
        info: DaemonInfo,
        eventBus: EventBus,
        methods: (any SessionMethodHandler)? = nil
    ) {
        self.transport = transport
        self.tools = tools
        self.status = status
        self.info = info
        self.eventBus = eventBus
        self.methods = methods
    }

    /// Sends a request to the peer and awaits its result — the app asking
    /// an extension to perform a command. Ids are strings prefixed
    /// `server-`, so they never collide with the client's numeric ids.
    ///
    /// - Parameters:
    ///   - method: The method name.
    ///   - params: The params, if any.
    /// - Returns: The peer's result.
    /// - Throws: ``SessionRequestError``.
    public func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        let id = "server-\(nextRequestNumber)"
        nextRequestNumber += 1
        let payload = try MessageCoder.encode(OutgoingRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.writeMessage(payload)
                } catch {
                    settle(id, with: .failure(SessionRequestError.transport(String(describing: error))))
                }
            }
        }
    }

    /// Runs the session until the peer closes the connection (a read of nil)
    /// or a read error, then tears down: cancels the notifier and closes the
    /// transport.
    public func run() async {
        eventBus.event("mcp.session.opened", domain: .control)
        while !Task.isCancelled {
            let payload: Data?
            do {
                payload = try await transport.readMessage()
            } catch {
                eventBus.trace(
                    "mcp.session.read",
                    domain: .control,
                    params: ["error": .string(String(describing: error))]
                )
                break
            }
            guard let payload else { break }  // Peer closed the connection.
            await handle(payload)
        }
        notifierTask?.cancel()
        await transport.close()
        endPending()
        eventBus.event("mcp.session.closed", domain: .control)
    }

    /// Decodes and dispatches one incoming message.
    private func handle(_ payload: Data) async {
        let incoming: JSONRPCIncoming
        do {
            incoming = try MessageCoder.decode(payload)
        } catch {
            // An unparseable line has no id to answer against; per JSON-RPC
            // the daemon simply does not respond (a lenient stdio server).
            eventBus.trace(
                "mcp.message.undecodable",
                domain: .control,
                params: ["error": .string(String(describing: error))]
            )
            return
        }

        // A request carries both method and id; a notification carries a
        // method and no id; a response (id, no method) settles a request
        // this side sent — none from the daemon, the app's command requests
        // to an extension.
        guard let method = incoming.method else {
            if case .string(let id)? = incoming.id { settle(id, with: responseResult(payload)) }
            return
        }
        guard let id = incoming.id else {
            await handleNotification(method: method, params: incoming.params)
            return
        }
        let response = await respond(method: method, id: id, params: incoming.params)
        await send(response)
    }

    /// The result or protocol error a response payload carries.
    private func responseResult(_ payload: Data) -> Result<JSONValue, any Error> {
        guard let response = try? JSONDecoder().decode(IncomingResponse.self, from: payload) else {
            return .failure(SessionRequestError.undecodableResponse)
        }
        if let error = response.error { return .failure(SessionRequestError.peer(error)) }
        return .success(response.result ?? .null)
    }

    /// Resumes the request `id` with `result`.
    private func settle(_ id: String, with result: Result<JSONValue, any Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    /// Ends every pending request as closed.
    private func endPending() {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: SessionRequestError.closed)
        }
    }

    /// Handles a client notification. Only `notifications/initialized`
    /// matters in v1; anything else is ignored.
    private func handleNotification(method: String, params: JSONValue?) async {
        // The notifier already starts when the daemon answers `initialize`,
        // so the client's `initialized` ack needs nothing; every other
        // notification is the endpoint's own to handle (the app tier's
        // `tingra/event`).
        guard method != MCPProtocol.initialized else { return }
        await methods?.handleNotification(method: method, params: params)
    }

    /// Builds the response for a request method.
    private func respond(method: String, id: JSONRPCID, params: JSONValue?) async -> JSONRPCResponse {
        switch method {
        case MCPProtocol.initialize:
            initialized = true
            startNotifier()
            return .success(id: id, result: info.initializeResult)

        case MCPProtocol.ping:
            return .success(id: id, result: .object([:]))

        case MCPProtocol.toolsList:
            guard initialized else { return notInitialized(id) }
            let descriptors = await tools.allTools.map(MCPToolDescriptor.descriptor(for:))
            return .success(id: id, result: .object(["tools": .array(descriptors)]))

        case MCPProtocol.toolsCall:
            guard initialized else { return notInitialized(id) }
            return await callTool(id: id, params: params)

        default:
            guard let methods else { return unknownMethod(id, method) }
            guard initialized else { return notInitialized(id) }
            do {
                guard let result = try await methods.respond(method: method, params: params) else {
                    return unknownMethod(id, method)
                }
                return .success(id: id, result: result)
            } catch let error as JSONRPCError {
                return .failure(id: id, error: error)
            } catch {
                return .failure(id: id, error: JSONRPCError(code: .internalError, message: String(describing: error)))
            }
        }
    }

    /// The response to a method nobody serves.
    private func unknownMethod(_ id: JSONRPCID, _ method: String) -> JSONRPCResponse {
        .failure(id: id, error: JSONRPCError(code: .methodNotFound, message: "Unknown method '\(method)'."))
    }

    /// Dispatches a `tools/call` against the registry, rendering the outcome
    /// as an MCP tool result (a *successful* JSON-RPC response even for a
    /// tool that reported a failure — MCP.md, "Errors that teach").
    private func callTool(id: JSONRPCID, params: JSONValue?) async -> JSONRPCResponse {
        guard let name = params?["name"]?.stringValue else {
            return .failure(
                id: id,
                error: JSONRPCError(code: .invalidParams, message: "A tools/call requires a string 'name'.")
            )
        }
        let arguments = params?["arguments"] ?? .object([:])
        guard let tool = await tools.tool(named: name) else {
            let error = ToolError(
                identifier: .invalidArgument,
                message: "No tool named '\(name)' is registered. Call tools/list for the available tools."
            )
            return .success(id: id, result: MCPToolResult.failure(error).resultValue)
        }
        do {
            let output = try await tool.call(arguments)
            return .success(id: id, result: MCPToolResult.success(output).resultValue)
        } catch let toolError as ToolError {
            return .success(id: id, result: MCPToolResult.failure(toolError).resultValue)
        } catch {
            // Any non-ToolError escaping a tool is an internal pipeline fault;
            // it still reaches the agent as a structured, identifier-keyed
            // result rather than taking anything down (CLAUDE.md never-crash).
            let toolError = ToolError(identifier: .pipelineError, message: String(describing: error))
            return .success(id: id, result: MCPToolResult.failure(toolError).resultValue)
        }
    }

    /// The error response for a `tools/*` request that arrives before the
    /// `initialize` handshake.
    private func notInitialized(_ id: JSONRPCID) -> JSONRPCResponse {
        .failure(
            id: id,
            error: JSONRPCError(
                code: .invalidRequest,
                message: "The session is not initialized; send 'initialize' first."
            )
        )
    }

    /// Starts (once) the task forwarding status changes to this session as
    /// `notifications/message`. Fed by the status sink's broadcast stream —
    /// the engine pushes; this session never polls.
    private func startNotifier() {
        guard notifierTask == nil else { return }
        let transport = self.transport
        let status = self.status
        notifierTask = Task {
            for await event in await status.updates() {
                let notification = JSONRPCNotification(
                    method: MCPProtocol.message,
                    params: StatusNotification.params(for: event)
                )
                guard let payload = try? MessageCoder.encode(notification) else { continue }
                try? await transport.writeMessage(payload)
            }
        }
    }

    /// Encodes and writes one response, tolerating a write failure (a peer
    /// that vanished mid-response ends the session on the next read).
    private func send(_ response: JSONRPCResponse) async {
        guard let payload = try? MessageCoder.encode(response) else { return }
        try? await transport.writeMessage(payload)
    }
}

/// A request this side sends (the app asking an extension to perform a
/// command).
private struct OutgoingRequest: Encodable {
    /// The protocol version tag.
    let jsonrpc = "2.0"

    /// The request id.
    let id: String

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

/// A response the peer sends to a request this side made.
private struct IncomingResponse: Decodable {
    /// The result, on success.
    let result: JSONValue?

    /// The error, on a protocol failure.
    let error: JSONRPCError?
}

/// Answers the methods an endpoint serves beyond MCP's own — the app tier's
/// `tingra/*` methods (storage and events; MCP.md, "The app tier") — so
/// ``MCPSession`` stays one session type for the daemon's socket and the
/// app's XPC link.
public protocol SessionMethodHandler: Sendable {
    /// Answers a request, or returns nil when the method is not one of this
    /// handler's (the session then answers method-not-found).
    ///
    /// - Parameters:
    ///   - method: The method name.
    ///   - params: The params, if any.
    /// - Returns: The result, or nil for an unknown method.
    /// - Throws: A `JSONRPCError` to answer with that protocol error; any
    ///   other error answers as an internal error.
    func respond(method: String, params: JSONValue?) async throws -> JSONValue?

    /// Handles a notification (no response is possible).
    ///
    /// - Parameters:
    ///   - method: The method name.
    ///   - params: The params, if any.
    func handleNotification(method: String, params: JSONValue?) async
}

/// What a request the session sends to its peer can get wrong.
public enum SessionRequestError: Error, Equatable, CustomStringConvertible {
    /// The session ended before the peer answered.
    case closed

    /// The transport reported an error sending the request.
    case transport(String)

    /// The peer answered with a JSON-RPC error.
    case peer(JSONRPCError)

    /// The peer's response did not decode.
    case undecodableResponse

    public var description: String {
        switch self {
        case .closed: "The session closed before the peer answered."
        case .transport(let detail): "The request could not be sent: \(detail)"
        case .peer(let error): "The peer answered with JSON-RPC error \(error.code): \(error.message)"
        case .undecodableResponse: "The peer's response does not decode."
        }
    }
}
