//
//  Shot.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A stable identifier for a ``Shot`` (GLOSSARY.md, "Shot"). String-backed
/// like ``InputID`` so it survives round-tripping through the persisted
/// project document, and defaults to a fresh UUID for shots created at
/// runtime; app-built default shots use fixed ids (e.g. `"pip"`) so a shot's
/// identity is stable across rebuilds.
public struct ShotID: RawRepresentable, Hashable, Sendable, Codable {
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

/// A short-term composition: an ordered arrangement of layers plus the
/// background they sit over (GLOSSARY.md, "Shot"). The compositor renders a
/// shot's layer tree to a single program frame each tick, and a shot is taken
/// to program by ``Compositor/take(shotID:)`` (a cut).
///
/// A shot carries a stable ``id`` and a user-facing ``name`` so it can live in
/// a ``Preset``, be listed in a switcher, and be taken to program by id. It is
/// a plain `Codable` value type — the persistence format is a project /
/// scripting contract (CLAUDE.md, "Data Models"), so its JSON keys are stable
/// camelCase and it round-trips exactly.
///
/// Layers are ordered **bottom to top**: `layers[0]` is drawn first (nearest
/// the background) and later layers composite over it. A shot with no layers
/// (or whose layers' inputs have no frames yet) renders as the background
/// alone — the program is always a live canvas at the tick rate, even before
/// any input delivers (CLOCK.md, "The program tick").
public struct Shot: Sendable, Equatable, Codable, Identifiable {
    /// The shot's stable identity, unique within its preset — what
    /// ``Compositor/take(shotID:)`` selects and what a switcher keys off.
    public let id: ShotID

    /// The user-facing name shown in a shot switcher (e.g. "Picture in
    /// Picture"). Empty for an unnamed ad-hoc shot.
    public let name: String

    /// The layer tree, bottom to top.
    public let layers: [Layer]

    /// The background the layers composite over, as straight RGBA in
    /// `0`...`1`. Defaults to opaque black — the broadcast-safe empty
    /// program.
    public let background: BackgroundColor

    /// The transition this shot is taken to program with when the caller
    /// does not name one explicitly — how a switcher's Default choice
    /// resolves per shot (ARCHITECTURE.md, "Per-shot default transitions").
    /// `nil` (the default) means no per-shot preference: an unresolved take
    /// is a cut, the behavior every shot had before this field existed.
    ///
    /// The compositor never reads it: `take(shotID:transition:)` still takes
    /// exactly the transition it is passed, and resolving a default against
    /// an operator's override is the caller's decision.
    public let defaultTransition: Transition?

    /// Creates a shot.
    ///
    /// - Parameters:
    ///   - id: The shot's stable identity (default: a fresh UUID).
    ///   - name: The user-facing name (default: empty).
    ///   - layers: The layer tree, bottom to top (default: none).
    ///   - background: The background color (default: opaque black).
    ///   - defaultTransition: The transition an unresolved take uses
    ///     (default: none — a cut).
    public init(
        id: ShotID = ShotID(),
        name: String = "",
        layers: [Layer] = [],
        background: BackgroundColor = .black,
        defaultTransition: Transition? = nil
    ) {
        self.id = id
        self.name = name
        self.layers = layers
        self.background = background
        self.defaultTransition = defaultTransition
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case layers
        case background
        case defaultTransition
    }

    /// Decodes a shot. `id` and `name` are required (a persisted shot has an
    /// identity and a name); `layers` and `background` are optional and
    /// default to an empty tree over opaque black, so a minimal hand-written
    /// shot is valid; `defaultTransition` is optional and absent means no
    /// default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ShotID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        layers = try container.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        background = try container.decodeIfPresent(BackgroundColor.self, forKey: .background) ?? .black
        defaultTransition = try container.decodeIfPresent(Transition.self, forKey: .defaultTransition)
    }

    /// Encodes a shot, always writing every field — except
    /// `defaultTransition`, written only when set, so a shot with no default
    /// round-trips to a document without the key (and reads back as nil, the
    /// same rule as `Project`'s `destination`).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(layers, forKey: .layers)
        try container.encode(background, forKey: .background)
        try container.encodeIfPresent(defaultTransition, forKey: .defaultTransition)
    }
}

/// A straight (non-premultiplied) RGBA background color in `0`...`1`
/// components — the fill the compositor clears the program frame to before
/// drawing the layer tree.
public struct BackgroundColor: Sendable, Equatable, Codable {
    /// The red component, `0`...`1`.
    public let red: Double

    /// The green component, `0`...`1`.
    public let green: Double

    /// The blue component, `0`...`1`.
    public let blue: Double

    /// The alpha component, `0`...`1`.
    public let alpha: Double

    /// Creates a background color from straight RGBA components.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Opaque black — the default empty program background.
    public static let black = BackgroundColor(red: 0, green: 0, blue: 0, alpha: 1)
}
