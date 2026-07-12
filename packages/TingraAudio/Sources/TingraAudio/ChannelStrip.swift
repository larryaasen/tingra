//
//  ChannelStrip.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// One input's slot in the mixer: the input and its level and mute
/// (GLOSSARY.md, "Channel strip" — pan, routing, and the audio effect chain
/// are later iterations; see ARCHITECTURE.md, "The audio mixer").
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

    /// Whether the strip is muted — a muted strip contributes silence to the
    /// mix regardless of its level.
    public var isMuted: Bool

    /// Creates a channel strip.
    ///
    /// - Parameters:
    ///   - input: The audio input this strip mixes.
    ///   - level: The strip's linear gain (default unity).
    ///   - isMuted: Whether the strip starts muted (default no).
    public init(input: any Input, level: Double = 1, isMuted: Bool = false) {
        self.input = input
        self.level = level
        self.isMuted = isMuted
    }
}
