//
//  Preset.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A stable identifier for a ``Preset``. String-backed like ``ShotID`` and
/// ``InputID`` so it survives the persisted project document; defaults to a
/// fresh UUID.
public struct PresetID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string — a UUID by default, or a caller-chosen stable
    /// token.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fresh, unique identifier (a new UUID string).
    public init() {
        self.rawValue = UUID().uuidString
    }
}

/// A named, persisted collection of shots you switch between during a live
/// session (GLOSSARY.md, "Preset"). A project holds several presets; each
/// holds the shots the operator cuts among on program.
///
/// A preset is a plain `Codable` value type — it is the persisted document,
/// so its JSON keys are a stable project / scripting contract (CLAUDE.md,
/// "Data Models") and it round-trips exactly. It deliberately holds no
/// "active shot": which shot is currently on program is live **session**
/// state owned by the ``Compositor`` (GLOSSARY.md, "Session"), not part of the
/// saved document. Loading a preset (``Compositor/loadPreset(_:)``) makes its
/// first shot active; audio configuration, connected inputs, and destinations
/// join the preset in later iterations.
public struct Preset: Sendable, Equatable, Codable, Identifiable {
    /// The preset's stable identity, unique within its project.
    public let id: PresetID

    /// The user-facing name shown when switching presets.
    public let name: String

    /// The shots the operator cuts among, in switcher order.
    public let shots: [Shot]

    /// Creates a preset.
    ///
    /// - Parameters:
    ///   - id: The preset's stable identity (default: a fresh UUID).
    ///   - name: The user-facing name.
    ///   - shots: The shots, in switcher order (default: none).
    public init(id: PresetID = PresetID(), name: String, shots: [Shot] = []) {
        self.id = id
        self.name = name
        self.shots = shots
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case shots
    }

    /// Decodes a preset. `id` and `name` are required; `shots` is optional and
    /// defaults to empty, so a freshly created preset with no shots is valid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PresetID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        shots = try container.decodeIfPresent([Shot].self, forKey: .shots) ?? []
    }

    /// Encodes a preset, always writing every field so the document
    /// round-trips exactly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(shots, forKey: .shots)
    }
}
