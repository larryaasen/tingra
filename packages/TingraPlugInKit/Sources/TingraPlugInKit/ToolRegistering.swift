//
//  ToolRegistering.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The registration seam where tool plug-ins attach: the host's tool
/// registry, narrowed to the one thing a plug-in may do with it —
/// contribute MCP tools (see GLOSSARY.md, "Registry" and "Seam", and
/// MCP.md, "Tool surface").
///
/// Defined here rather than in the host package so a plug-in can register
/// tools without depending on the engine; the host's `ToolRegistry`
/// conforms and arrives through ``PlugInContext/tools``, mirroring
/// ``InputRegistering`` and ``OutputRegistering``.
public protocol ToolRegistering: Sendable {
    /// Registers a tool contributed by a plug-in.
    ///
    /// Throws a descriptive error if the tool cannot be accepted — for
    /// example, when another tool is already registered under the same name
    /// (tool names are unique; a duplicate is a plug-in defect, surfaced as
    /// a thrown error, never a trap).
    func register(_ tool: any Tool) async throws
}
