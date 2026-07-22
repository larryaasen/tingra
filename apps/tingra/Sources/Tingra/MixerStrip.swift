//
//  MixerStrip.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraComposition
import TingraPlugInKit

/// One channel strip as the mixer panel shows it: an audio input's level,
/// pan, mute, and effect chain (GLOSSARY.md, "Channel strip"). The
/// engine-side strip lives in the mixer
/// (`TingraAudio.ChannelStrip`, which carries the running input); this is
/// the app's observable session state for it, kept even while the strip's
/// device is muted (and therefore stopped) or absent.
///
/// Strip settings **persist in the active preset** as its authored audio
/// channels (`TingraComposition.AudioChannel`), synced back and autosaved
/// like shot edits; the session strips are built by ``strips(channels:discovered:)``
/// merging the authored channels with live discovery (see ARCHITECTURE.md,
/// "Per-strip routing").
struct MixerStrip: Identifiable, Equatable {
    /// The audio input's stable identifier — the device UID, so a persisted
    /// strip finds its device again across launches.
    let id: InputID

    /// The input's user-facing name: as discovery reported it, or as the
    /// document cached it while the device is absent.
    let name: String

    /// The strip's linear gain, `0` (silent) to `1` (unity) — what the
    /// panel's level slider edits.
    var level: Double

    /// The strip's pan position, `-1` (hard left) through `0` (center) to
    /// `1` (hard right) — what the panel's pan slider edits (double-click
    /// recenters it).
    var pan: Double

    /// Whether the strip is muted. In the app, muting also stops the
    /// strip's device (the microphone indicator goes dark); the strip keeps
    /// its settings for unmute.
    var isMuted: Bool

    /// The strip's effect chain, in signal order — what the strip's
    /// effects popover edits (GLOSSARY.md, "Channel strip";
    /// ARCHITECTURE.md, "Audio effect chains"). Configurations only: the
    /// live effect instances belong to the mixer, instantiated from these
    /// through the effect registry. Empty for no chain.
    var effects: [EffectConfiguration] = []

    /// Seeds the session's strips from the discovered audio inputs — the
    /// no-authored-audio fallback of ``strips(channels:discovered:)``: the
    /// first input unmuted at unity — the successor of the CLI-era "first
    /// microphone streams" default — and every other input muted at unity,
    /// present on the panel but silent (and not capturing) until the
    /// operator unmutes it. Every strip seeds centered.
    ///
    /// - Parameter inputs: The discovered audio inputs, in listing order.
    /// - Returns: One strip per input.
    static func seed(from inputs: [EngineModel.InputChoice]) -> [MixerStrip] {
        inputs.enumerated().map { index, input in
            MixerStrip(id: input.id, name: input.name, level: 1, pan: 0, isMuted: index != 0)
        }
    }

    /// Merges a preset's authored audio channels with the discovered audio
    /// inputs into the session's strips (ARCHITECTURE.md, "Per-strip
    /// routing"):
    ///
    /// - Passed `nil` — no authored audio configuration — it falls back to
    ///   the ``seed(from:)`` policy over discovery alone.
    /// - Authored channels come first, in document order (the panel order
    ///   *is* the persisted array order), each with its authored settings. A
    ///   channel whose device is discovered takes the freshly discovered
    ///   name; one whose device is **absent** stays a dormant strip — the
    ///   document's cached name (falling back to the raw id), settings still
    ///   editable, contributing silence until the device returns — the
    ///   layer-bound-to-an-undiscovered-input semantic, one service over.
    /// - Discovered inputs with no authored channel append after, in
    ///   discovery order, **muted** at unity, centered: a device the preset
    ///   never authorized is never surprise-live on program.
    ///
    /// - Parameters:
    ///   - channels: The active preset's authored channels, or `nil` when it
    ///     has none.
    ///   - inputs: The discovered audio inputs, in listing order.
    /// - Returns: The merged strips, in panel order.
    static func strips(channels: [AudioChannel]?, discovered inputs: [EngineModel.InputChoice]) -> [MixerStrip] {
        guard let channels else { return seed(from: inputs) }
        let authored = channels.map { channel in
            let discoveredName = inputs.first { $0.id == channel.input }?.name
            let cachedName = channel.name.isEmpty ? channel.input.rawValue : channel.name
            return MixerStrip(
                id: channel.input,
                name: discoveredName ?? cachedName,
                level: channel.level,
                pan: channel.pan,
                isMuted: channel.isMuted,
                effects: channel.effects ?? []
            )
        }
        let authoredIDs = Set(channels.map(\.input))
        let appended = inputs.filter { !authoredIDs.contains($0.id) }.map { input in
            MixerStrip(id: input.id, name: input.name, level: 1, pan: 0, isMuted: true)
        }
        return authored + appended
    }

    /// The strip as the project document persists it — one authored channel
    /// of the active preset's audio configuration. A chainless strip
    /// authors no `effects` key (nil, not an empty list), so a document
    /// that never touched effects encodes exactly as it did before the
    /// chain existed.
    ///
    /// - Returns: The strip's `AudioChannel`.
    var audioChannel: AudioChannel {
        AudioChannel(
            input: id, name: name, level: level, pan: pan, isMuted: isMuted,
            effects: effects.isEmpty ? nil : effects)
    }
}
