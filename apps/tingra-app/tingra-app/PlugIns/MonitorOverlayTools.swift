//
//  MonitorOverlayTools.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// What the monitor overlay tool acts on: the engine model, behind a seam
/// so the tool is tested against a fake with no engine booted. Main-actor
/// isolated like the model; the tool hops there for the length of one
/// call.
@MainActor
protocol MonitorOverlayControlling: AnyObject, Sendable {
    /// Every registered monitor overlay, in menu order.
    var monitorOverlayCatalog: MonitorOverlayCatalog { get }

    /// The overlays on a monitor, in the order they were turned on.
    func monitorOverlayIDs(on target: MonitorOverlayTarget) -> [MonitorOverlayID]

    /// Whether an overlay has anything to show on a monitor.
    func isMonitorOverlayAvailable(_ provider: any MonitorOverlayProvider, on target: MonitorOverlayTarget) -> Bool

    /// Turns an overlay on or off for a monitor.
    func setMonitorOverlay(_ id: MonitorOverlayID, on target: MonitorOverlayTarget, isOn: Bool)
}

/// The first-party monitor overlay tools plug-in: `monitor_overlay_set`,
/// the Overlays submenus' checkmarks as an MCP tool (PLUGINS.md, "Slice 3
/// as built"), registered through the same `ToolRegistering` seam every
/// tool plug-in uses. App-owned for the program tools' reason: only the app
/// has monitors.
nonisolated struct MonitorOverlayToolsPlugIn: PlugIn {
    let id = PlugInID(rawValue: "com.moonwink.tingra.monitorOverlayTools")
    let name = "Monitor Overlay Tools"

    /// The monitors the tool acts on.
    private let overlays: any MonitorOverlayControlling

    /// Creates the plug-in over the app's monitors.
    ///
    /// - Parameter overlays: The monitors' overlays.
    init(overlays: any MonitorOverlayControlling) {
        self.overlays = overlays
    }

    /// Registers `monitor_overlay_set`.
    ///
    /// - Parameter context: The host's registration seams.
    /// - Throws: The tool registry's error when the name is taken.
    func activate(in context: PlugInContext) async throws {
        try await context.tools.register(MonitorOverlaySetTool(overlays: overlays))
    }
}

/// The `monitor_overlay_set` tool: turns one monitor overlay on or off for
/// one monitor, the way its item in that monitor's Overlays submenu does.
/// State, not a toggle: it says what the overlay should be, and reports
/// whether that `changed` anything, as the program output tools do
/// (PLUGINS.md, Decision 17).
nonisolated struct MonitorOverlaySetTool: Tool {
    /// The monitors the tool acts on.
    private let overlays: any MonitorOverlayControlling

    /// Creates the tool.
    init(overlays: any MonitorOverlayControlling) {
        self.overlays = overlays
    }

    /// The monitors the tool accepts, as the `monitor` argument names them.
    static let monitorNames = ["program", "preview", "input", "layer"]

    let name = "monitor_overlay_set"
    let title = "Set Monitor Overlay"
    let description =
        "Turn a monitor overlay (a safe area, a crop guide, a tally border, zebra stripes, VU meters, and so on) on "
        + "or off for one monitor. Monitor overlays are drawn for the operator alone and never reach the program, "
        + "a destination, a recording, or a snapshot. 'monitor' is program, preview, input (every multiview input "
        + "tile), or layer (the layer monitor). 'overlay' is an overlay's id or name; an unknown one is answered "
        + "with every overlay's id and name. Returns the overlay, whether it is on, whether that 'changed', and "
        + "every overlay now on that monitor. Saved with the project."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "monitor": .object([
                "type": .string("string"),
                "enum": .array(MonitorOverlaySetTool.monitorNames.map { .string($0) }),
                "description": .string("The monitor: program, preview, input (every input tile), or layer."),
            ]),
            "overlay": .object([
                "type": .string("string"),
                "description": .string(
                    "The overlay, by id or by name: an exact id wins; otherwise a case-insensitive name that "
                        + "matches exactly one overlay, such as 'Title Safe'."),
            ]),
            "on": .object([
                "type": .string("boolean"),
                "description": .string("true to show the overlay on the monitor, false to hide it."),
            ]),
        ]),
        "required": .array([.string("monitor"), .string("overlay"), .string("on")]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        guard let monitor = arguments["monitor"]?.stringValue, Self.monitorNames.contains(monitor) else {
            throw ToolError(
                identifier: .invalidArgument,
                message: "monitor_overlay_set requires 'monitor': one of program, preview, input, or layer.")
        }
        guard let selector = arguments["overlay"]?.stringValue, !selector.isEmpty else {
            throw ToolError(
                identifier: .invalidArgument,
                message: "monitor_overlay_set requires 'overlay', the id or name of a monitor overlay.")
        }
        guard let isOn = arguments["on"]?.boolValue else {
            throw ToolError(identifier: .invalidArgument, message: "monitor_overlay_set requires 'on', true or false.")
        }
        return try await MainActor.run {
            guard let target = MonitorOverlayTarget(rawValue: monitor) else {
                throw ToolError(
                    identifier: .invalidArgument,
                    message: "monitor_overlay_set requires 'monitor': one of program, preview, input, or layer.")
            }
            let provider = try Self.resolve(selector, in: overlays.monitorOverlayCatalog.providers)
            if isOn, !overlays.isMonitorOverlayAvailable(provider, on: target) {
                throw ToolError(
                    identifier: .invalidArgument,
                    message:
                        "\(provider.name) has nothing to show on the \(monitor) monitor now, so it was not turned "
                        + "on. Show Alpha needs an input tile or the layer monitor, VU Meters a monitor with sound, "
                        + "and a crop guide a program of another aspect.")
            }
            let wasOn = overlays.monitorOverlayIDs(on: target).contains(provider.id)
            overlays.setMonitorOverlay(provider.id, on: target, isOn: isOn)
            return .object([
                "monitor": .string(monitor),
                "overlay": .object(["id": .string(provider.id.rawValue), "name": .string(provider.name)]),
                "on": .bool(isOn),
                "changed": .bool(wasOn != isOn),
                "overlays": .array(overlays.monitorOverlayIDs(on: target).map { .string($0.rawValue) }),
            ])
        }
    }

    /// The overlay a selector names: an exact id wins outright, otherwise a
    /// case-insensitive name that matches exactly one overlay.
    ///
    /// - Parameters:
    ///   - selector: The id or name.
    ///   - providers: The registered overlays.
    /// - Returns: The overlay.
    /// - Throws: `monitorOverlayNotFound`, listing every overlay, when
    ///   nothing matches or a name matches more than one.
    static func resolve(
        _ selector: String, in providers: [any MonitorOverlayProvider]
    ) throws -> any MonitorOverlayProvider {
        if let byID = providers.first(where: { $0.id.rawValue == selector }) { return byID }
        let byName = providers.filter { $0.name.caseInsensitiveCompare(selector) == .orderedSame }
        if byName.count == 1 { return byName[0] }
        let known = providers.map { "'\($0.name)' (\($0.id.rawValue))" }.joined(separator: ", ")
        let reason =
            byName.isEmpty
            ? "No monitor overlay has the id or name '\(selector)'."
            : "'\(selector)' names \(byName.count) monitor overlays; use the id."
        throw ToolError(
            identifier: .monitorOverlayNotFound,
            message: known.isEmpty ? "\(reason) No monitor overlay is registered." : "\(reason) The overlays: \(known)."
        )
    }
}
