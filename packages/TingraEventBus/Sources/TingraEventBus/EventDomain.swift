//
//  EventDomain.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The attribution axis of an event: which part of the system emitted it.
///
/// Well known domains mirror the engine services; third party plug-ins use
/// their plug-in identifier as the domain. The set is open (string backed,
/// not a closed enum) because plug-ins must be able to add their own without
/// touching the host (see EVENTS.md).
public struct EventDomain: RawRepresentable, Hashable, Sendable, Codable {
    /// The domain identifier, e.g. `"capture"` or a plug-in identifier.
    public let rawValue: String

    /// Creates a domain from its identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a domain from its identifier (unlabeled convenience for
    /// plug-in defined domains).
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The well known domains, mirroring the engine services in ARCHITECTURE.md.
extension EventDomain {
    /// Inputs, generators, input discovery, device connection and disconnection.
    public static let capture = EventDomain("capture")

    /// Presets, shots, layer tree, transitions, renderer, effects, program/preview buses.
    public static let composition = EventDomain("composition")

    /// Mixer, channel strips, routing, audio effects.
    public static let audio = EventDomain("audio")

    /// Compression sessions, rate control, local recording.
    public static let compression = EventDomain("compression")

    /// The `StreamingService` seam and its implementations.
    public static let output = EventDomain("output")

    /// Plug-in discovery, lifecycle, isolation.
    public static let plugIn = EventDomain("plugin")

    /// MCP/Control: tool registry, session/state, authorization bridge.
    public static let control = EventDomain("control")

    /// Event bus, logging, secure storage, local storage, system info.
    public static let platform = EventDomain("platform")

    /// The live running state of the engine.
    public static let session = EventDomain("session")
}
