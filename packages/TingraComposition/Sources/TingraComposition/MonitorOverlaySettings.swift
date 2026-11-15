//
//  MonitorOverlaySettings.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Which monitor overlays a project shows on each kind of monitor, and
/// each overlay's parameter values (GLOSSARY.md, "Monitor overlay";
/// PLUGINS.md, Decision 55): the project's `monitorOverlays` key. The
/// program and preview monitors each keep a list; every input tile shares
/// one, since the tiles are interchangeable; and the layer monitor keeps
/// its own.
///
/// In the project because a show framed for a vertical platform needs its
/// 9:16 guide back when it reopens, and another project must not inherit
/// it. The parameter values are per overlay, shared by both monitors: a
/// title-safe percentage is the same wherever it is drawn. An id this
/// build has no provider for round-trips untouched, so an overlay returns
/// as it was when its plug-in does. Which overlays are on when a project
/// has no settings yet is the front end's policy, not this type's.
public struct MonitorOverlaySettings: Sendable, Equatable, Codable {
    /// The overlays on the program monitor, in the order they were turned
    /// on. Drawing order comes from the registry, never from this list.
    public var program: [MonitorOverlayID]

    /// The overlays on the preview monitor, in the order they were turned
    /// on.
    public var preview: [MonitorOverlayID]

    /// The overlays on every input tile, in the order they were turned on.
    public var input: [MonitorOverlayID]

    /// The overlays on the layer monitor, in the order they were turned
    /// on.
    public var layer: [MonitorOverlayID]

    /// Each overlay's parameter values, keyed by the raw value of its id,
    /// then by its declared parameter keys. An overlay with no stored
    /// values has no entry and draws at its declared defaults.
    public var parameters: [String: [String: JSONValue]]

    /// Creates settings.
    ///
    /// - Parameters:
    ///   - program: The overlays on the program monitor (default: none).
    ///   - preview: The overlays on the preview monitor (default: none).
    ///   - input: The overlays on every input tile (default: none).
    ///   - layer: The overlays on the layer monitor (default: none).
    ///   - parameters: The overlays' parameter values (default: none).
    public init(
        program: [MonitorOverlayID] = [],
        preview: [MonitorOverlayID] = [],
        input: [MonitorOverlayID] = [],
        layer: [MonitorOverlayID] = [],
        parameters: [String: [String: JSONValue]] = [:]
    ) {
        self.program = program
        self.preview = preview
        self.input = input
        self.layer = layer
        self.parameters = parameters
    }

    /// The overlays on one kind of monitor. Setting a monitor kind this
    /// build does not know changes nothing.
    ///
    /// - Parameter monitor: The kind of monitor.
    public subscript(monitor: MonitorOverlayContext.Monitor) -> [MonitorOverlayID] {
        get {
            switch monitor {
            case .program: program
            case .preview: preview
            case .input: input
            case .layer: layer
            @unknown default: []
            }
        }
        set {
            switch monitor {
            case .program: program = newValue
            case .preview: preview = newValue
            case .input: input = newValue
            case .layer: layer = newValue
            @unknown default: break
            }
        }
    }

    /// The coding keys: stable camelCase names in the project document.
    private enum CodingKeys: String, CodingKey {
        case program
        case preview
        case input
        case layer
        case parameters
    }

    /// Decodes settings. Every key is optional and reads as empty when
    /// absent, so a document that names only one monitor's overlays
    /// decodes.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A `DecodingError` when a key is present with the wrong
    ///   shape.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        program = try container.decodeIfPresent([MonitorOverlayID].self, forKey: .program) ?? []
        preview = try container.decodeIfPresent([MonitorOverlayID].self, forKey: .preview) ?? []
        input = try container.decodeIfPresent([MonitorOverlayID].self, forKey: .input) ?? []
        layer = try container.decodeIfPresent([MonitorOverlayID].self, forKey: .layer) ?? []
        parameters = try container.decodeIfPresent([String: [String: JSONValue]].self, forKey: .parameters) ?? [:]
    }

    /// Encodes the settings, writing `program` and `preview` always, so an
    /// operator who turned every overlay off saves exactly that, and
    /// `input`, `layer`, and `parameters` only when they hold something,
    /// since their default is empty.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An `EncodingError` when a value cannot be written.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(program, forKey: .program)
        try container.encode(preview, forKey: .preview)
        if !input.isEmpty {
            try container.encode(input, forKey: .input)
        }
        if !layer.isEmpty {
            try container.encode(layer, forKey: .layer)
        }
        if !parameters.isEmpty {
            try container.encode(parameters, forKey: .parameters)
        }
    }
}
