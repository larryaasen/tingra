//
//  PlugIn.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus

/// A stable, reverse-DNS identifier for a plug-in, e.g.
/// `com.moonwink.tingra.input.camera`. Third party plug-ins use their own
/// domain. The identifier doubles as the plug-in's event domain (see
/// EVENTS.md).
public struct PlugInID: RawRepresentable, Hashable, Sendable, Codable {
    /// The reverse-DNS identifier string.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// What the host hands a plug-in when it loads: the shared host
/// infrastructure a plug-in is allowed to touch, plus the registration
/// seams it contributes capabilities through.
///
/// Each registration seam is a protocol defined in this package and
/// conformed to by the host's registry, keeping the host/plug-in boundary
/// explicit. Further seams (generators, effects, outputs, tools) join as
/// their registries land.
public struct PlugInContext: Sendable {
    /// The host's event bus. Plug-ins report everything that happens as
    /// events; they never log directly (see EVENTS.md).
    public let eventBus: EventBus

    /// The master clock (see CLOCK.md). Inputs use it to normalize
    /// timestamps; generators stamp synthesized frames with it.
    public let clock: any EngineClock

    /// The input registration seam: where the plug-in registers the inputs
    /// it contributes during ``PlugIn/activate(in:)``.
    public let inputs: any InputRegistering

    /// The output registration seam: where the plug-in registers the
    /// streaming service providers it contributes during
    /// ``PlugIn/activate(in:)``.
    public let outputs: any OutputRegistering

    /// The effect registration seam: where the plug-in registers the
    /// audio and video effect providers it contributes during
    /// ``PlugIn/activate(in:)`` (see ARCHITECTURE.md, "The effect seam").
    /// A pre-1.0 addition, like ``OutputRegistering``'s recording overload
    /// (ARCHITECTURE.md, "Plug-in API stability and versioning").
    public let effects: any EffectRegistering

    /// The tool registration seam: where the plug-in registers the MCP
    /// tools it contributes during ``PlugIn/activate(in:)`` (see MCP.md,
    /// "Tool surface").
    public let tools: any ToolRegistering

    /// Creates the context the host hands a plug-in at activation.
    public init(
        eventBus: EventBus,
        clock: any EngineClock,
        inputs: any InputRegistering,
        outputs: any OutputRegistering,
        effects: any EffectRegistering,
        tools: any ToolRegistering
    ) {
        self.eventBus = eventBus
        self.clock = clock
        self.inputs = inputs
        self.outputs = outputs
        self.effects = effects
        self.tools = tools
    }
}

/// A unit of capability added to the engine: inputs, generators, effects,
/// transitions, outputs, automation (see GLOSSARY.md).
///
/// First party and third party plug-ins conform to the identical protocol
/// and register through the same registries. In the CLI era, bundled
/// plug-ins are compiled in but register through the same code path the
/// external bundle loader will use.
public protocol PlugIn: Sendable {
    /// The plug-in's stable identifier, also its event domain.
    var id: PlugInID { get }

    /// A short human readable name, e.g. "Camera Input".
    var name: String { get }

    /// Called once when the host loads the plug-in. The plug-in registers
    /// its capabilities into the host's registries here.
    ///
    /// Throws a descriptive error if the plug-in cannot activate; the host
    /// reports it as an `error` event and the remaining plug-ins load
    /// normally — a plug-in must never take down the host (CLAUDE.md,
    /// never-crash rule).
    func activate(in context: PlugInContext) async throws
}
