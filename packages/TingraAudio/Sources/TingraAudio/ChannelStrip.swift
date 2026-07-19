//
//  ChannelStrip.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// One input's slot in the mixer: the input and its level, pan, and mute
/// (GLOSSARY.md, "Channel strip" — the audio effect chain is a later
/// iteration; see ARCHITECTURE.md, "The audio mixer", "Per-strip pan").
/// Routing needs no surface here: the program mix is the only bus, so a
/// strip's routing is its membership in the mix — the strips the caller
/// passes to ``AudioMixer/setChannelStrips(_:)`` — and its persisted form is
/// the document's `AudioChannel`, not this live type (ARCHITECTURE.md,
/// "Per-strip routing").
///
/// A strip's mute silences its channel in the program mix without touching
/// the input's device lifecycle — whether a muted input keeps capturing is
/// the caller's policy (the app stops a muted strip's device so the
/// microphone indicator stays honest; a future monitoring path may keep it
/// running).
public struct ChannelStrip: Sendable {
    /// The audio input this strip mixes.
    public let input: any Input

    /// The strip's linear gain, `0` (silent) to `1` (unity) and above
    /// (boost). Negative values are treated as `0`.
    public var level: Double

    /// The strip's stereo pan position, `-1` (hard left) through `0`
    /// (center, the default) to `1` (hard right); values outside that range
    /// are clamped at the mix. The mixer applies the equal-power law
    /// normalized to unity at center, so a centered strip mixes exactly as
    /// it did before pan existed; on a mono source pan is a constant-power
    /// panner, on a stereo source it acts as a balance — the two channels
    /// are scaled, never folded into each other (ARCHITECTURE.md,
    /// "Per-strip pan").
    public var pan: Double

    /// Whether the strip is muted — a muted strip contributes silence to the
    /// mix regardless of its level.
    public var isMuted: Bool

    /// Creates a channel strip.
    ///
    /// - Parameters:
    ///   - input: The audio input this strip mixes.
    ///   - level: The strip's linear gain (default unity).
    ///   - pan: The strip's pan position (default center).
    ///   - isMuted: Whether the strip starts muted (default no).
    public init(input: any Input, level: Double = 1, pan: Double = 0, isMuted: Bool = false) {
        self.input = input
        self.level = level
        self.pan = pan
        self.isMuted = isMuted
    }
}
