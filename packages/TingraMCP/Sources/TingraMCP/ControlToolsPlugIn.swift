//
//  ControlToolsPlugIn.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraHost
import TingraPlugInKit

/// The first-party control tools plug-in: contributes the MCP tool set that
/// mirrors the CLI surface (`devices_list`, `probe`, `stream_start`,
/// `stream_status`, `stream_stop`) through the same ``ToolRegistering`` seam
/// a third-party tool plug-in uses (MCP.md, "Tool surface").
///
/// The stream tools share one ``StreamCoordinator`` — injected rather than
/// created here so the daemon can also read it for the idle-exit guard
/// (never idle-exit mid-stream). The registries the read-only tools need
/// (`devices_list`, `probe`) are injected concretely because those tools
/// resolve and enumerate, which the narrow registration seam does not expose.
public struct ControlToolsPlugIn: PlugIn {
    /// The plug-in identifier, also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.control")

    /// The plug-in's human-readable name.
    public let name = "Control Tools"

    /// The shared coordinator the stream tools drive.
    private let coordinator: StreamCoordinator

    /// The input registry `devices_list` enumerates.
    private let inputs: InputRegistry

    /// The output registry `probe` resolves against.
    private let outputs: OutputRegistry

    /// Creates the plug-in.
    ///
    /// - Parameters:
    ///   - coordinator: The shared stream coordinator.
    ///   - inputs: The host input registry.
    ///   - outputs: The host output registry.
    public init(coordinator: StreamCoordinator, inputs: InputRegistry, outputs: OutputRegistry) {
        self.coordinator = coordinator
        self.inputs = inputs
        self.outputs = outputs
    }

    /// Registers every first-party tool into the host's tool registry.
    public func activate(in context: PlugInContext) async throws {
        try await context.tools.register(DevicesListTool(inputs: inputs))
        try await context.tools.register(ProbeTool(outputs: outputs))
        try await context.tools.register(StreamStartTool(coordinator: coordinator))
        try await context.tools.register(StreamStatusTool(coordinator: coordinator))
        try await context.tools.register(StreamStopTool(coordinator: coordinator))
    }
}
