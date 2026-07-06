//
//  MCPProtocol.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The MCP methods and notification names the daemon understands, plus the
/// protocol version it speaks. Constants rather than scattered string
/// literals so the wire vocabulary lives in one place (see MCP.md).
public enum MCPProtocol {
    /// The MCP protocol revision the daemon implements. Reported in the
    /// `initialize` result; a client comparing revisions negotiates from it.
    public static let version = "2025-06-18"

    /// `initialize` — the first request of every MCP session; the daemon
    /// replies with its capabilities and build version.
    public static let initialize = "initialize"

    /// `notifications/initialized` — the client's acknowledgement that the
    /// handshake is complete. A notification (no response).
    public static let initialized = "notifications/initialized"

    /// `ping` — a liveness check; the daemon replies with an empty result.
    public static let ping = "ping"

    /// `tools/list` — enumerate the registered tools and their input schemas.
    public static let toolsList = "tools/list"

    /// `tools/call` — invoke one tool by name with arguments.
    public static let toolsCall = "tools/call"

    /// `notifications/message` — the standard MCP logging notification the
    /// daemon uses to push status changes to connected sessions (MCP.md,
    /// "Sessions and concurrency").
    public static let message = "notifications/message"
}

/// The daemon's identity, reported in the `initialize` result so a client
/// can detect version skew after an upgrade (MCP.md, "Version skew").
public struct DaemonInfo: Sendable, Equatable {
    /// The daemon's product name, e.g. `tingra`.
    public let name: String

    /// The daemon's build version, e.g. `0.0.1-dev`.
    public let version: String

    /// Creates a daemon info value.
    ///
    /// - Parameters:
    ///   - name: The product name reported to clients.
    ///   - version: The build version reported to clients.
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    /// The `initialize` result body (a ``JSONValue`` object) advertising the
    /// protocol version, the tools and logging capabilities, and this
    /// daemon's identity.
    public var initializeResult: JSONValue {
        .object([
            "protocolVersion": .string(MCPProtocol.version),
            "capabilities": .object([
                // The tool set is fixed for the life of a v1 session, so the
                // list never changes underneath a client.
                "tools": .object(["listChanged": .bool(false)]),
                // The daemon pushes status as logging notifications.
                "logging": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string(name),
                "version": .string(version),
            ]),
        ])
    }
}

/// One tool as it appears in a `tools/list` result: the machine name, a
/// human title, a description, and the JSON Schema for its arguments.
enum MCPToolDescriptor {
    /// Builds the `tools/list` entry (a ``JSONValue`` object) for a tool.
    static func descriptor(for tool: any Tool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "title": .string(tool.title),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
        ])
    }
}

/// The result of a `tools/call`: MCP represents a tool that *ran* but
/// reported a failure as a normal result with `isError` true, so the agent
/// sees the structured detail rather than a transport-level fault (MCP.md,
/// "Errors that teach").
struct MCPToolResult {
    /// The structured result the tool returned (success) or the error detail
    /// (failure).
    let structured: JSONValue

    /// Whether the call reported a failure.
    let isError: Bool

    /// A success result wrapping the tool's structured output.
    static func success(_ value: JSONValue) -> MCPToolResult {
        MCPToolResult(structured: value, isError: false)
    }

    /// A failure result from a ``ToolError``: the structured content carries
    /// the stable identifier and the actionable message, both also rendered
    /// into the human-readable text block.
    static func failure(_ error: ToolError) -> MCPToolResult {
        MCPToolResult(
            structured: .object([
                "identifier": .string(error.identifier.rawValue),
                "message": .string(error.message),
            ]),
            isError: true
        )
    }

    /// The `tools/call` result body (a ``JSONValue`` object): a text content
    /// block carrying a JSON rendering (for any client), the same value as
    /// `structuredContent` (for schema-aware clients), and the `isError`
    /// flag.
    var resultValue: JSONValue {
        let text = JSONText.encode(structured)
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ]),
            "structuredContent": structured,
            "isError": .bool(isError),
        ])
    }
}
