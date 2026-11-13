//
//  MixerStrip.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraCapturePlugIns
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
/// like shot edits; the session strips are built by
/// ``strips(channels:discovered:preferring:)`` from the authored channels,
/// named from live discovery (see ARCHITECTURE.md, "Per-strip routing").
///
/// **The mixer holds what the show uses, not what is connected** (the
/// amendment of 2026-11-07). Discovery never adds a strip: a strip exists
/// because the operator added it (``added(_:)``), because a fresh project
/// seeded one (``seed(from:preferring:)``), or because a video file with
/// sound was placed in a shot (``mediaStrip(for:strips:discovered:)``).
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

    /// Whether the strip's audio **follows video**: it feeds the program mix
    /// only while its input is in the program shot (GLOSSARY.md, "Audio
    /// follows video"; ARCHITECTURE.md, "Audio follows video") — what the
    /// strip's AFV toggle edits. Nil only while unauthored *and* unresolved:
    /// a dormant strip from a document that never authored it, whose kind
    /// discovery has not reported yet. Nil reads as off
    /// (``isFollowingProgram``) and is persisted as an absent key, so the
    /// sync-back never freezes that guess into the document — the first
    /// discovery resolves it by kind (``defaultFollowsProgram(for:)``).
    var followsProgram: Bool?

    /// Whether the strip's audio follows video, nil read as off — what the
    /// toggle shows and what program presence is computed from.
    var isFollowingProgram: Bool { followsProgram ?? false }

    /// The audio-follows-video default for an input of a given provenance:
    /// **on for media with a picture**, off for everything else. A clip's
    /// sound comes and goes with its picture; a microphone stays live across
    /// takes, and a generator is a test signal the operator patched on
    /// purpose. An **audio file** is media with no picture: it can never be
    /// in a shot, so a strip that followed video would never reach the
    /// program mix — music plays under the show whatever shot is up
    /// (ARCHITECTURE.md, "Audio files as media inputs").
    ///
    /// - Parameters:
    ///   - kind: The input's provenance.
    ///   - hasPicture: Whether the input also produces video (true by
    ///     default — the question only matters for media, and every media
    ///     input but an audio file has one).
    /// - Returns: Whether a new strip for it follows video.
    static func defaultFollowsProgram(for kind: InputKind, hasPicture: Bool = true) -> Bool {
        kind == .media && hasPicture
    }

    /// Whether the strip reaches the program mix as far as audio follows
    /// video is concerned: always when AFV is off, and otherwise only while
    /// its input is on program. Mute and connection are separate questions
    /// the caller asks beside this one.
    ///
    /// - Parameter programInputs: The inputs in the program shot.
    /// - Returns: Whether the strip is present on program.
    func isPresent(onProgram programInputs: Set<InputID>) -> Bool {
        !isFollowingProgram || programInputs.contains(id)
    }

    /// The program presence the mixer should hold for every strip, given
    /// the inputs in the program shot — the membership rule of audio follows
    /// video as a pure function (ARCHITECTURE.md, "Audio follows video").
    ///
    /// Across a take, `programInputs` is the **incoming** shot's: an AFV
    /// strip whose input only the outgoing shot holds is absent (it ramps
    /// down), one only the incoming shot holds is present (it ramps up), and
    /// one both hold is present throughout — it stays up. A strip with AFV
    /// off is always present, so turning AFV off on a strip that was off
    /// program brings it back.
    ///
    /// - Parameters:
    ///   - strips: The mixer's strips.
    ///   - programInputs: The inputs in the program shot.
    /// - Returns: Each strip's presence, keyed by its input id.
    static func programPresence(of strips: [MixerStrip], onProgram programInputs: Set<InputID>) -> [InputID: Bool] {
        Dictionary(
            strips.map { ($0.id, $0.isPresent(onProgram: programInputs)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Seeds the session's strips from the discovered audio inputs — the
    /// no-authored-audio fallback of ``strips(channels:discovered:preferring:)``:
    /// **one** strip, unmuted at unity and centered — the successor of the
    /// CLI-era "first microphone streams" default. The inputs the seed
    /// passes over are not strips at all; they stay in the sidebar for the
    /// operator to add (ARCHITECTURE.md, "Per-strip routing", the amendment
    /// of 2026-11-07).
    ///
    /// The strip is the **system default microphone** when discovery holds
    /// it, so a fresh project opens on the microphone macOS is already
    /// using, and otherwise the first captured input in listing order.
    ///
    /// A **generator, a media file, or an application is never seeded**,
    /// even when it sorts first by name (the 440 Hz tone does), and even when
    /// it is passed as the default. Unmuting also starts the input, so
    /// seeding a generator would put a test tone on the program mix — and on
    /// any stream — the first time an operator opened a fresh project, and
    /// seeding an application would take its sound off the operator's
    /// speakers unasked. When the only audio
    /// inputs are generators or media, the seed is empty: an empty mixer the
    /// operator can add to is right where an unrequested tone is not.
    ///
    /// - Parameters:
    ///   - inputs: The discovered audio inputs, in listing order.
    ///   - defaultMicrophone: The system default microphone's id, or nil when
    ///     there is none (or in a test that does not care).
    /// - Returns: The seeded strip, or no strips when no device is discovered.
    static func seed(
        from inputs: [EngineModel.InputChoice],
        preferring defaultMicrophone: InputID? = nil
    ) -> [MixerStrip] {
        // A device, never a generator or a media file: the seed is what is
        // live out of the box, and neither a test tone nor a movie's sound
        // is what an operator asked for by launching the app.
        let devices = inputs.filter { $0.kind != .generator && $0.kind != .media && $0.kind != .application }
        guard let live = devices.first(where: { $0.id == defaultMicrophone }) ?? devices.first else { return [] }
        return [
            MixerStrip(
                id: live.id, name: live.name, level: 1, pan: 0, isMuted: false,
                followsProgram: defaultFollowsProgram(for: live.kind))
        ]
    }

    /// The strip an operator's **Add Channel** makes for an input: muted at
    /// unity, centered, with no effect chain, and audio follows video set
    /// explicitly by the input's kind (``defaultFollowsProgram(for:hasPicture:)``) —
    /// on for a video file, off for a microphone, a generator, or an audio
    /// file. Muted because adding a channel
    /// is a patch, not opening the fader — an operator adding a microphone
    /// mid-show must never put it on air by doing so; the mute is the one
    /// step that does.
    ///
    /// - Parameters:
    ///   - input: The audio input being added.
    ///   - hasPicture: Whether the input also produces video (true by
    ///     default; false for an audio file, whose strip must not follow a
    ///     picture it does not have).
    /// - Returns: The new strip.
    static func added(_ input: EngineModel.InputChoice, hasPicture: Bool = true) -> MixerStrip {
        MixerStrip(
            id: input.id, name: input.name, level: 1, pan: 0, isMuted: true,
            followsProgram: defaultFollowsProgram(for: input.kind, hasPicture: hasPicture))
    }

    /// The strip placing an input in a shot adds, when that input is a
    /// **media file with sound** that is not on the mixer yet — or nil.
    ///
    /// Putting the file in a shot is the use, so its sound needs no separate
    /// add; the strip arrives muted, like every added strip (``added(_:)``),
    /// with audio follows video on — the media default.
    /// Only media qualifies: a microphone or a generator is never added
    /// implicitly, and a camera's or display's picture says nothing about a
    /// sound. The audio list is what decides "has sound" — a media input is
    /// in it only when the file has an audio track.
    ///
    /// - Parameters:
    ///   - input: The input just placed in a shot.
    ///   - strips: The current strips.
    ///   - discovered: The discovered audio inputs.
    /// - Returns: The strip to append, or nil when there is nothing to add.
    static func mediaStrip(
        for input: InputID,
        strips: [MixerStrip],
        discovered: [EngineModel.InputChoice]
    ) -> MixerStrip? {
        guard !strips.contains(where: { $0.id == input }),
            let choice = discovered.first(where: { $0.id == input }),
            choice.kind == .media
        else { return nil }
        return added(choice)
    }

    /// Builds the session's strips from a preset's authored audio channels,
    /// named from the discovered audio inputs (ARCHITECTURE.md, "Per-strip
    /// routing", as amended 2026-11-07):
    ///
    /// - An authored channel naming a private aggregate device
    ///   (`PrivateAggregateDevice.matches(uid:)`) is dropped before any of
    ///   this, so a document that authored one is cleaned on its next sync.
    /// - Passed `nil` — no authored audio configuration — it falls back to
    ///   the ``seed(from:preferring:)`` policy over discovery alone.
    /// - The strips are the authored channels, in document order (the panel
    ///   order *is* the persisted array order), each with its authored
    ///   settings. A channel whose device is discovered takes the freshly
    ///   discovered name; one whose id is not discovered first looks for its
    ///   device **by name**, since a USB device without a serial number
    ///   changes id with its port (``resolvedInputs(for:discovered:)``); one
    ///   whose device is still not found is **absent** and stays a dormant
    ///   strip — the document's cached name (falling back to the raw id),
    ///   settings still editable, contributing silence until the device
    ///   returns — the layer-bound-to-an-undiscovered-input semantic, one
    ///   service over.
    /// - A channel that never authored audio follows video resolves it by
    ///   its discovered input's kind (``defaultFollowsProgram(for:)``); a
    ///   dormant one stays unresolved — off — until its device is
    ///   discovered (ARCHITECTURE.md, "Audio follows video").
    /// - A discovered input with no authored channel is **not** a strip. It
    ///   was one, muted, until 2026-11-07; but the sync-back authored every
    ///   such strip on the next save, so a device seen once stayed on the
    ///   mixer for good. Now a newly connected device appears in the sidebar
    ///   and nowhere else — a stronger "never surprise-live" than the muted
    ///   append was.
    ///
    /// - Parameters:
    ///   - channels: The active preset's authored channels, or `nil` when it
    ///     has none.
    ///   - inputs: The discovered audio inputs, in listing order.
    ///   - defaultMicrophone: The system default microphone, which the seed
    ///     prefers when `channels` is nil (default: none).
    /// - Returns: The strips, in panel order.
    static func strips(
        channels: [AudioChannel]?,
        discovered inputs: [EngineModel.InputChoice],
        preferring defaultMicrophone: InputID? = nil
    ) -> [MixerStrip] {
        guard let authoredChannels = channels else { return seed(from: inputs, preferring: defaultMicrophone) }
        // A channel naming one of macOS's private aggregate devices is not a
        // dormant strip waiting for its device: the device was the monitor's
        // own plumbing, dead with the launch that authored it, and no
        // discovery offers it again. Dropping it here is what cleans a
        // document that authored one before the capture plug-in declined
        // them — on the next sync, with no migration.
        let channels = authoredChannels.filter { !PrivateAggregateDevice.matches(uid: $0.input.rawValue) }
        let resolved = resolvedInputs(for: channels, discovered: inputs)
        return zip(channels, resolved).map { channel, id in
            let discovered = inputs.first { $0.id == id }
            let discoveredName = discovered?.name
            let cachedName = channel.name.isEmpty ? channel.input.rawValue : channel.name
            return MixerStrip(
                id: id,
                name: discoveredName ?? cachedName,
                level: channel.level,
                pan: channel.pan,
                isMuted: channel.isMuted,
                effects: channel.effects ?? [],
                // Unauthored resolves by the discovered input's kind; a
                // dormant strip's kind is not known yet, so it stays
                // unresolved (off) until its device is discovered.
                followsProgram: channel.followsProgram ?? discovered.map { defaultFollowsProgram(for: $0.kind) }
            )
        }
    }

    /// The input each authored channel binds to, in channel order: its own
    /// id when discovery holds it, and otherwise — **found by name** — the
    /// one discovered device that is plainly the same device under a new id.
    ///
    /// A USB audio device without a serial number gets its uniqueID from its
    /// **USB port** (`AppleUSBAudioEngine:Dell:Dell AC511 USB SoundBar:113000:2,1`,
    /// the location ID before the interface numbers), so the same soundbar
    /// moved to another port is a different id, and its channel would sit
    /// dormant beside a live device that is not on the mixer. The camera
    /// presets met the same fact and find their camera by id, then by name
    /// (docs/UVC.md); this is that rule for strips (ARCHITECTURE.md,
    /// "Per-strip routing", the amendment of 2026-11-07, found the same day).
    ///
    /// A channel takes a device by name only when the match is unambiguous
    /// and the device is free:
    /// - the channel's id is not discovered, and it has a cached name;
    /// - exactly **one** discovered input has that name (two identical
    ///   webcams cannot be told apart by name, so neither is guessed);
    /// - no other channel holds that device by its exact id, and no earlier
    ///   channel has taken it by name — a device is never two strips.
    ///
    /// Anything else stays bound to its own id, a dormant strip as before.
    /// The rebound strip carries the device's current id, so the next sync
    /// writes it into the preset and the document follows the device.
    ///
    /// - Parameters:
    ///   - channels: The authored channels, in document order.
    ///   - inputs: The discovered audio inputs.
    /// - Returns: One input id per channel, in the same order.
    private static func resolvedInputs(
        for channels: [AudioChannel],
        discovered inputs: [EngineModel.InputChoice]
    ) -> [InputID] {
        let discoveredIDs = Set(inputs.map(\.id))
        var claimed = Set(channels.map(\.input).filter { discoveredIDs.contains($0) })
        return channels.map { channel in
            guard !discoveredIDs.contains(channel.input), !channel.name.isEmpty else { return channel.input }
            let sameName = inputs.filter { $0.name == channel.name }
            guard sameName.count == 1, let device = sameName.first, !claimed.contains(device.id) else {
                return channel.input
            }
            claimed.insert(device.id)
            return device.id
        }
    }

    /// The strip as the project document persists it — one authored channel
    /// of the active preset's audio configuration. A chainless strip
    /// authors no `effects` key (nil, not an empty list), so a document
    /// that never touched effects encodes exactly as it did before the
    /// chain existed; an unresolved ``followsProgram`` authors no
    /// `followsProgram` key, for the same reason.
    ///
    /// - Returns: The strip's `AudioChannel`.
    var audioChannel: AudioChannel {
        AudioChannel(
            input: id, name: name, level: level, pan: pan, isMuted: isMuted,
            effects: effects.isEmpty ? nil : effects, followsProgram: followsProgram)
    }
}
