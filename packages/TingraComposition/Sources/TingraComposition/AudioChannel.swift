//
//  AudioChannel.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-19.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// One authored channel of a preset's audio configuration: a channel strip
/// as the project document persists it — the input it mixes and the strip
/// settings the operator authored (level, pan, mute). The live mixing strip
/// stays `TingraAudio.ChannelStrip` (it carries the running input); this is
/// the document's record of it, living beside ``Preset`` because the
/// document types live together (the ``ProjectDestination`` precedent).
///
/// **Routing, v1:** the program mix is the only bus, so a channel's routing
/// *is* its membership in a preset's ``Preset/audioChannels`` — the channel
/// feeds the program mix, and there is nowhere else to route it. Sends and
/// additional buses are later iterations (ARCHITECTURE.md, "Per-strip
/// routing").
///
/// The ``input`` identity is the device UID the `InputID` already carries
/// (an `AVCaptureDevice.uniqueID` for a microphone), so a channel finds its
/// device again across reconnection and relaunch; ``name`` caches the
/// device's user-facing name as last discovered, so a channel whose device
/// is absent still renders a labeled strip.
///
/// A plain `Codable` value type on the project / scripting contract (stable
/// camelCase keys, exact round-trip), like ``Preset``/``Shot``/``Layer``.
public struct AudioChannel: Sendable, Equatable, Codable {
    /// The audio input this channel mixes — the discovery-stable device UID,
    /// so the channel rebinds to its device across launches.
    public let input: InputID

    /// The input's user-facing name as last discovered — the strip's label
    /// while the device is absent. Empty when never cached.
    public let name: String

    /// The strip's linear gain, `0` (silent) to `1` (unity) and above
    /// (boost).
    public let level: Double

    /// The strip's stereo pan position, `-1` (hard left) through `0`
    /// (center) to `1` (hard right).
    public let pan: Double

    /// Whether the strip is muted.
    public let isMuted: Bool

    /// The strip's authored effect chain, in signal order (the chain *is*
    /// its array — ARCHITECTURE.md, "The effect seam"), or nil for no
    /// chain. An **optional key within v1** (the pre-release rule, no
    /// version bump): absent means no chain, so every pre-effects document
    /// decodes unchanged.
    public let effects: [EffectConfiguration]?

    /// Creates an authored channel.
    ///
    /// - Parameters:
    ///   - input: The audio input this channel mixes.
    ///   - name: The input's user-facing name as last discovered (default
    ///     empty).
    ///   - level: The strip's linear gain (default unity).
    ///   - pan: The strip's pan position (default center).
    ///   - isMuted: Whether the strip is muted (default no).
    ///   - effects: The strip's authored effect chain, in signal order, or
    ///     nil (default) for no chain.
    public init(
        input: InputID,
        name: String = "",
        level: Double = 1,
        pan: Double = 0,
        isMuted: Bool = false,
        effects: [EffectConfiguration]? = nil
    ) {
        self.input = input
        self.name = name
        self.level = level
        self.pan = pan
        self.isMuted = isMuted
        self.effects = effects
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case input
        case name
        case level
        case pan
        case isMuted
        case effects
    }

    /// Decodes a channel. `input` is required — a channel without its device
    /// identity is meaningless; every setting decodes forgivingly to the
    /// strip defaults (empty name, unity level, centered pan, unmuted, no
    /// effect chain).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decode(InputID.self, forKey: .input)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        level = try container.decodeIfPresent(Double.self, forKey: .level) ?? 1
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        effects = try container.decodeIfPresent([EffectConfiguration].self, forKey: .effects)
    }

    /// Encodes a channel, always writing every settled field so the
    /// document round-trips exactly; the optional effect chain is written
    /// only when authored, so a chainless channel encodes as it did before
    /// effects existed.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(name, forKey: .name)
        try container.encode(level, forKey: .level)
        try container.encode(pan, forKey: .pan)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encodeIfPresent(effects, forKey: .effects)
    }
}
