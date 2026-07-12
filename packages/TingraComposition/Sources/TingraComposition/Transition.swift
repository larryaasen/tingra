//
//  Transition.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The move from one shot to the next (GLOSSARY.md, "Transition"). This
/// iteration implements ``cut`` (instant) and ``dissolve(duration:)``
/// (crossfade); `wipe` and custom shader based transitions are a later
/// iteration and are not yet representable by this type.
///
/// A plain `Codable` value type — the same project-file contract as
/// ``Preset``/``Shot`` (CLAUDE.md, "Data Models"): stable camelCase keys, so
/// a transition round-trips exactly wherever it is later persisted (a
/// preset's default transition, say). For now ``Compositor/take(shotID:transition:)``
/// takes one directly per call; it is not yet a field on ``Shot`` or
/// ``Preset`` (ARCHITECTURE.md, "Presets and shots").
public enum Transition: Sendable, Equatable, Codable {
    /// An instant switch: the outgoing shot is replaced by the incoming one
    /// on the very next program tick, with no blending — the behavior
    /// `take(shotID:)` always had before this iteration, and still the
    /// default.
    case cut

    /// A crossfade between the outgoing and incoming shot over `duration`
    /// seconds: the tick-paced renderer blends the two, ramping from fully
    /// outgoing to fully incoming.
    ///
    /// - Parameter duration: The crossfade length in seconds. The
    ///   compositor clamps it to at least one tick's worth of time, so a
    ///   zero or negative duration still transitions — just as fast as the
    ///   tick rate allows — rather than never completing.
    case dissolve(duration: TimeInterval)

    /// A dissolve at the default length (``defaultDissolveDuration``), the
    /// convenience most callers reach for.
    public static var dissolve: Transition { .dissolve(duration: defaultDissolveDuration) }

    /// The default crossfade length when a caller asks for a dissolve
    /// without naming a duration — a broadcast-typical half second.
    public static let defaultDissolveDuration: TimeInterval = 0.5

    /// The coding keys — stable camelCase names for the project contract.
    private enum CodingKeys: String, CodingKey {
        case kind
        case durationSeconds
    }

    /// The `kind` discriminator, written to and read from the `kind` key.
    private enum Kind: String, Codable {
        case cut
        case dissolve
    }

    /// Decodes a transition. `kind` is required; a dissolve's
    /// `durationSeconds` is optional and falls back to
    /// ``defaultDissolveDuration``, so a minimal hand-written
    /// `{"kind": "dissolve"}` is valid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .cut:
            self = .cut
        case .dissolve:
            let duration =
                try container.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
                ?? Transition.defaultDissolveDuration
            self = .dissolve(duration: duration)
        }
    }

    /// Encodes a transition, always writing every field for its kind so the
    /// document round-trips exactly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cut:
            try container.encode(Kind.cut, forKey: .kind)
        case .dissolve(let duration):
            try container.encode(Kind.dissolve, forKey: .kind)
            try container.encode(duration, forKey: .durationSeconds)
        }
    }
}
