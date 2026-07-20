//
//  Transition.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The move from one shot to the next (GLOSSARY.md, "Transition"): ``cut``
/// (instant), ``dissolve(duration:)`` (crossfade), ``wipe(edge:duration:)``
/// (directional reveal), or ``shader(name:duration:)`` (a custom
/// Metal-shader reveal from the built-in ``TransitionShader`` menu) — all
/// four GLOSSARY.md transition kinds.
///
/// A plain `Codable` value type — the same project-file contract as
/// ``Preset``/``Shot`` (CLAUDE.md, "Data Models"): stable camelCase keys, so
/// a transition round-trips exactly wherever it is persisted — a shot's
/// ``Shot/defaultTransition``. ``Compositor/take(shotID:transition:)`` still
/// takes one directly per call; resolving a shot's default against an
/// operator's override is the caller's decision (ARCHITECTURE.md, "Per-shot
/// default transitions").
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

    /// A directional reveal of the incoming shot over `duration` seconds:
    /// the incoming shot appears across the frame behind a boundary sweeping
    /// from `edge` to the opposite edge, the outgoing shot showing where the
    /// boundary has not yet passed.
    ///
    /// - Parameters:
    ///   - edge: The frame edge the incoming shot is revealed from.
    ///   - duration: The wipe length in seconds. The compositor clamps it to
    ///     at least one tick's worth of time — the same rule as a dissolve —
    ///     so a zero or negative duration still transitions.
    case wipe(edge: WipeEdge, duration: TimeInterval)

    /// A custom-shader reveal of the incoming shot over `duration` seconds:
    /// the named built-in Metal shader blends the outgoing and incoming shot
    /// per pixel as its progress ramps — the shapes a straight-edge wipe
    /// cannot draw (an iris, a diagonal, blinds).
    ///
    /// - Parameters:
    ///   - name: The built-in shader that draws the reveal.
    ///   - duration: The reveal length in seconds. The compositor clamps it
    ///     to at least one tick's worth of time — the same rule as a
    ///     dissolve — so a zero or negative duration still transitions.
    case shader(name: TransitionShader, duration: TimeInterval)

    /// A dissolve at the default length (``defaultDissolveDuration``), the
    /// convenience most callers reach for.
    public static var dissolve: Transition { .dissolve(duration: defaultDissolveDuration) }

    /// A wipe from the given edge at the default length
    /// (``defaultWipeDuration``), the convenience most callers reach for.
    ///
    /// - Parameter edge: The frame edge the incoming shot is revealed from
    ///   (default: the left edge).
    public static func wipe(edge: WipeEdge = .left) -> Transition {
        .wipe(edge: edge, duration: defaultWipeDuration)
    }

    /// A shader transition with the given built-in shader at the default
    /// length (``defaultShaderDuration``), the convenience most callers
    /// reach for.
    ///
    /// - Parameter name: The built-in shader that draws the reveal (default:
    ///   the iris).
    public static func shader(name: TransitionShader = .iris) -> Transition {
        .shader(name: name, duration: defaultShaderDuration)
    }

    /// The default crossfade length when a caller asks for a dissolve
    /// without naming a duration — a broadcast-typical half second.
    public static let defaultDissolveDuration: TimeInterval = 0.5

    /// The default wipe length when a caller asks for a wipe without naming
    /// a duration — the same broadcast-typical half second as a dissolve.
    public static let defaultWipeDuration: TimeInterval = 0.5

    /// The default shader-transition length when a caller asks for one
    /// without naming a duration — the same broadcast-typical half second
    /// as a dissolve.
    public static let defaultShaderDuration: TimeInterval = 0.5

    /// The coding keys — stable camelCase names for the project contract.
    /// A shader transition's ``TransitionShader`` is written under the
    /// `shader` key (the kind-specific aspect, like a wipe's `edge`).
    private enum CodingKeys: String, CodingKey {
        case kind
        case durationSeconds
        case edge
        case shader
    }

    /// The `kind` discriminator, written to and read from the `kind` key.
    private enum Kind: String, Codable {
        case cut
        case dissolve
        case wipe
        case shader
    }

    /// Decodes a transition. `kind` is required; a dissolve's, wipe's, or
    /// shader transition's `durationSeconds` — and a wipe's `edge` or a
    /// shader transition's `shader` — are optional and fall back to the
    /// defaults (``defaultDissolveDuration``, ``defaultWipeDuration``,
    /// ``defaultShaderDuration``, ``WipeEdge/left``,
    /// ``TransitionShader/iris``), so a minimal hand-written
    /// `{"kind": "dissolve"}`, `{"kind": "wipe"}`, or `{"kind": "shader"}`
    /// is valid. An unknown `shader` name throws, like an unknown `kind` or
    /// `edge` — a document naming a shader this build does not carry must
    /// not silently take with a different look.
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
        case .wipe:
            let edge = try container.decodeIfPresent(WipeEdge.self, forKey: .edge) ?? .left
            let duration =
                try container.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
                ?? Transition.defaultWipeDuration
            self = .wipe(edge: edge, duration: duration)
        case .shader:
            let name = try container.decodeIfPresent(TransitionShader.self, forKey: .shader) ?? .iris
            let duration =
                try container.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
                ?? Transition.defaultShaderDuration
            self = .shader(name: name, duration: duration)
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
        case .wipe(let edge, let duration):
            try container.encode(Kind.wipe, forKey: .kind)
            try container.encode(edge, forKey: .edge)
            try container.encode(duration, forKey: .durationSeconds)
        case .shader(let name, let duration):
            try container.encode(Kind.shader, forKey: .kind)
            try container.encode(name, forKey: .shader)
            try container.encode(duration, forKey: .durationSeconds)
        }
    }
}

/// The built-in menu of custom-shader transitions — the shapes the wipe's
/// straight edges cannot draw (its record deferred "diagonals, irises, and
/// patterns" to exactly this menu), each a hand-written Metal kernel
/// compiled into the app.
///
/// **The menu is first-party and fixed**: shader source ships as compiled-in
/// constants, and a project document can only *name* an entry here — no
/// path loads shader code from a document, a file, or user input; running
/// third-party shader code is a deliberately deferred plug-in-era surface
/// with its own security posture to record first (ARCHITECTURE.md,
/// "Custom-shader transitions"). The raw value is the stable camelCase
/// `shader` key of the project/scripting contract ``Transition`` carries,
/// and doubles as the Metal function name the renderer compiles.
public enum TransitionShader: String, Sendable, Equatable, Codable, CaseIterable {
    /// A circular reveal opening from the frame's center — the classic
    /// iris.
    case iris

    /// A diagonal sweep from the frame's top-left corner to its
    /// bottom-right.
    case diagonal

    /// Horizontal bands revealing in parallel — venetian blinds.
    case blinds
}

/// The frame edge a ``Transition/wipe(edge:duration:)`` reveals the incoming
/// shot from, its boundary sweeping to the opposite edge — the four
/// straight-edge directional reveals of a broadcast switcher. Diagonal,
/// iris, and patterned wipes belong with custom shader based transitions in
/// a later iteration, not as extra cases here.
///
/// Edges are named in the operator's screen terms (top-left origin, matching
/// ``Layer``'s normalized frame), and the raw value is the stable camelCase
/// `edge` key of the project/scripting contract ``Transition`` carries.
public enum WipeEdge: String, Sendable, Equatable, Codable, CaseIterable {
    /// The reveal starts at the left edge and sweeps right.
    case left

    /// The reveal starts at the right edge and sweeps left.
    case right

    /// The reveal starts at the top edge and sweeps down.
    case top

    /// The reveal starts at the bottom edge and sweeps up.
    case bottom
}
