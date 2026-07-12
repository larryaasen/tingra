//
//  MixerStrip.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// One channel strip as the mixer panel shows it: a discovered audio input's
/// level and mute (GLOSSARY.md, "Channel strip" — pan, routing, and the
/// audio effect chain are later iterations). The engine-side strip lives in
/// the mixer (`TingraAudio.ChannelStrip`, which carries the running input);
/// this is the app's observable session state for it, kept even while the
/// strip's device is muted and therefore stopped.
///
/// Strip settings are **session state** this iteration, like the active
/// shot — they join the persisted preset when routing lands (see
/// ARCHITECTURE.md, "The audio mixer").
struct MixerStrip: Identifiable, Equatable {
    /// The audio input's stable identifier.
    let id: InputID

    /// The input's user-facing name, as discovery reported it.
    let name: String

    /// The strip's linear gain, `0` (silent) to `1` (unity) — what the
    /// panel's level slider edits.
    var level: Double

    /// Whether the strip is muted. In the app, muting also stops the
    /// strip's device (the microphone indicator goes dark); the strip keeps
    /// its settings for unmute.
    var isMuted: Bool

    /// Seeds the session's strips from the discovered audio inputs: the
    /// first input unmuted at unity — the successor of the CLI-era "first
    /// microphone streams" default — and every other input muted at unity,
    /// present on the panel but silent (and not capturing) until the
    /// operator unmutes it.
    ///
    /// - Parameter inputs: The discovered audio inputs, in listing order.
    /// - Returns: One strip per input.
    static func seed(from inputs: [EngineModel.InputChoice]) -> [MixerStrip] {
        inputs.enumerated().map { index, input in
            MixerStrip(id: input.id, name: input.name, level: 1, isMuted: index != 0)
        }
    }
}
