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
actor MCPSession {
    /// The message channel for this connection.
    private let transport: any MessageTransport

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
    init(
        transport: any MessageTransport,
        tools: ToolRegistry,
        status: StatusSink,
        info: DaemonInfo,
        eventBus: EventBus
    ) {
        self.transport = transport
        self.tools = tools
        self.status = status
        self.info = info
        self.eventBus = eventBus
    }

    /// Runs the session until the peer closes the connection (a read of nil)
    /// or a read error, then tears down: cancels the notifier and closes the
    /// transport.
    func run() async {
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
        // method and no id; a client response (id, no method) is ignored —
        // the v1 daemon initiates no server-to-client requests.
        guard let method = incoming.method else { return }
        guard let id = incoming.id else {
            handleNotification(method: method)
            return
        }
        let response = await respond(method: method, id: id, params: incoming.params)
        await send(response)
    }

    /// Handles a client notification. Only `notifications/initialized`
    /// matters in v1; anything else is ignored.
    private func handleNotification(method: String) {
        // No action needed: the notifier already starts when the daemon
        // answers `initialize`, so the client's `initialized` ack is a no-op.
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
            return .failure(
                id: id,
                error: JSONRPCError(code: .methodNotFound, message: "Unknown method '\(method)'.")
            )
        }
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
