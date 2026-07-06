//
//  ToolRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Errors thrown by ``ToolRegistry``.
public enum ToolRegistryError: Error, Equatable {
    /// A tool with the same name is already registered. Tool names are
    /// unique and append-only (an MCP scripting contract); the fix is for
    /// the plug-in to give every tool it contributes a distinct name.
    case duplicateTool(String)
}

extension ToolRegistryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateTool(let name):
            return """
                A tool named '\(name)' is already registered. Tool names are unique across all \
                plug-ins and are a stable MCP contract; the plug-in contributing this tool must \
                give it a name no other tool claims.
                """
        }
    }
}

/// The seam where tool plug-ins attach: plug-ins register the MCP tools they
/// contribute, and the MCP/Control service resolves and lists them from here
/// (see MCP.md, "Tool surface"). Mirrors ``InputRegistry`` and
/// ``OutputRegistry``.
///
/// One registry instance per host; plug-ins receive it through the
/// registration path, never as a global. First-party tools register through
/// the same path a third party will use.
public actor ToolRegistry {
    /// The registered tools, keyed by their unique names.
    private var toolsByName: [String: any Tool] = [:]

    /// The order tools were registered in, so listing is stable and
    /// reflects load order rather than dictionary hashing.
    private var registrationOrder: [String] = []

    /// Creates an empty registry. The host owns one per engine.
    public init() {}

    /// Registers a tool contributed by a plug-in.
    ///
    /// Throws ``ToolRegistryError/duplicateTool(_:)`` if the name is already
    /// taken — a plug-in defect surfaces as a thrown error, never a trap
    /// (CLAUDE.md, never-crash rule).
    public func register(_ tool: any Tool) throws {
        guard toolsByName[tool.name] == nil else {
            throw ToolRegistryError.duplicateTool(tool.name)
        }
        toolsByName[tool.name] = tool
        registrationOrder.append(tool.name)
    }

    /// The tool registered under the given name, if any.
    public func tool(named name: String) -> (any Tool)? {
        toolsByName[name]
    }

    /// Every registered tool, in registration order — what the MCP/Control
    /// service returns from `tools/list`.
    public var allTools: [any Tool] {
        registrationOrder.compactMap { toolsByName[$0] }
    }
}

/// The registry is the concrete `ToolRegistering` seam the host hands
/// plug-ins through `PlugInContext.tools`.
extension ToolRegistry: ToolRegistering {}
