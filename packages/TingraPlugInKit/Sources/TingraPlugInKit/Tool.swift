//
//  Tool.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A structured, actionable failure from a ``Tool``'s ``Tool/call(_:)``.
///
/// Tool errors key off the append-only ``ErrorIdentifier`` registry — the
/// same identifiers the CLI's `error` events carry (see CLI.md, "Error
/// identifiers", and MCP.md, "Errors that teach"). The identifier is what
/// scripts and agents branch on; the `message` explains the cause and the
/// fix to a human and may be reworded across releases. A stream key must
/// never appear in a message.
public struct ToolError: Error, Equatable, Sendable {
    /// The stable, machine-readable failure identifier the agent branches
    /// on (never the message wording).
    public let identifier: ErrorIdentifier

    /// A developer/agent-facing explanation of what failed and how to fix
    /// it — an actionable message, never a secret.
    public let message: String

    /// Creates a tool error.
    ///
    /// - Parameters:
    ///   - identifier: The stable failure identifier.
    ///   - message: An actionable explanation of the cause and the fix.
    public init(identifier: ErrorIdentifier, message: String) {
        self.identifier = identifier
        self.message = message
    }
}

/// One control the engine exposes to AI agents as an MCP tool (see
/// GLOSSARY.md, "MCP tools"; MCP.md, "Tool surface").
///
/// Tools are plug-in contributed against the host's tool registry through
/// the ``ToolRegistering`` seam, exactly as inputs register through
/// ``InputRegistering`` and outputs through ``OutputRegistering`` — the
/// first-party tools register through the same path a third party will use,
/// so the agent-facing API and the plug-in API stay the same shape.
///
/// A tool's `name` and its input schema are a stable scripting contract
/// (see the Data Models rules in CLAUDE.md): append-only, camelCase result
/// keys, never renamed casually. A rename is a breaking change.
public protocol Tool: Sendable {
    /// The tool's machine name, unique in the registry, e.g. `devices_list`
    /// (MCP tool names are snake_case by MCP convention). Append-only: once
    /// shipped, never renamed or reused.
    var name: String { get }

    /// A short human-facing title for the tool, e.g. "List Devices".
    var title: String { get }

    /// A description of what the tool does, shown to the agent so it can
    /// choose the tool. Written for a reader who cannot see the code.
    var description: String { get }

    /// The JSON Schema (a ``JSONValue`` object) describing the tool's
    /// arguments — the `inputSchema` MCP returns from `tools/list`. An
    /// argument-less tool returns an empty object schema
    /// (`["type": "object"]`).
    var inputSchema: JSONValue { get }

    /// Runs the tool with the agent-supplied arguments and returns its
    /// structured result.
    ///
    /// - Parameter arguments: The `tools/call` arguments as a ``JSONValue``
    ///   object (or ``JSONValue/null`` when the caller sent none), validated
    ///   by the tool itself against its ``inputSchema``.
    /// - Returns: The structured result, surfaced to the agent as the call's
    ///   structured content.
    /// - Throws: A ``ToolError`` for an actionable, identifier-keyed failure
    ///   (the MCP/Control service renders it as a tool error result); any
    ///   other thrown error is reported under ``ErrorIdentifier/pipelineError``.
    func call(_ arguments: JSONValue) async throws -> JSONValue
}
