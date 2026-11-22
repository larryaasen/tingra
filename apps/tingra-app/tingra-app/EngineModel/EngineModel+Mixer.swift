//
//  EngineModel+Mixer.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraComposition
import TingraPlugInKit

/// The mixer: its channel strips' levels, pans, and mutes, and which inputs are on it.
extension EngineModel {
    /// Rebuilds the mixer's strips against the refreshed audio inputs, so a
    /// departed device's strip goes dormant and a returning one's comes back
    /// to life. A device the preset never authored gets no strip: it appears
    /// in the sidebar, for the operator to add (ARCHITECTURE.md, "Per-strip
    /// routing", the amendment of 2026-11-07).
    ///
    /// **The active preset is synced first, and that is load-bearing rather
    /// than tidiness.** It preserves the operator's un-autosaved level, pan,
    /// and mute edits across the refresh — but more importantly it guarantees
    /// the merge below is handed an *authored* channel list. Passing `nil`
    /// would fall through to ``MixerStrip/seed(from:)``, which unmutes the
    /// first non-generator strip — and unmuting also **starts** the device —
    /// so a newly connected microphone that happened to sort first by name
    /// would go live on the program mix, and on any stream, without being
    /// asked. The seed is a boot-time fallback only; every refresh takes the
    /// authored path, where a device the preset never authored gets no strip
    /// at all (ARCHITECTURE.md, "Live device lists in the app").
    func refreshMixerStrips() async {
        syncActivePreset()
        guard let channels = presets.first(where: { $0.id == activePresetID })?.audioChannels else { return }
        let strips = MixerStrip.strips(channels: channels, discovered: audioInputs)
        guard strips != mixerStrips else { return }
        mixerStrips = strips
        await reconfigureAudio()
    }

    /// Mutes or unmutes the master — the program's sound off air, its
    /// picture kept (GLOSSARY.md, "Master mute"). Everything fed from the
    /// program mix goes silent: every streaming destination, any recording,
    /// and the monitor. The strips keep their settings and their devices, so
    /// unmuting brings back exactly the mix that was there.
    ///
    /// Independent of ``setFadeToBlack(_:duration:)``: the mixer multiplies
    /// the two, so bringing the program up from black leaves a muted master
    /// muted. The mixer reports `master.mute`; the toggle's own `tap`
    /// records the click.
    ///
    /// - Parameter isMuted: Whether the master is muted.
    func setMasterMuted(_ isMuted: Bool) {
        isMasterMuted = isMuted
        mixer.setMasterMuted(isMuted)
    }

    /// Sets one channel strip's level, applied to the program mix from the
    /// next mix tick. Gesture-rate (a slider drag calls it many times a
    /// second), so it reports nothing itself — the slider's drag-end `tap`
    /// event carries the observability, the same convention as the layer
    /// sliders (EVENTS.md) — and the autosave is debounced, so the drag
    /// coalesces into one write (the `updateShot` rule; strip settings
    /// persist in the active preset — ARCHITECTURE.md, "Per-strip routing").
    ///
    /// - Parameters:
    ///   - level: The strip's linear gain, `0`...`1`.
    ///   - id: The strip's input id.
    func setStripLevel(_ level: Double, forStrip id: InputID) {
        guard let index = mixerStrips.firstIndex(where: { $0.id == id }) else { return }
        mixerStrips[index].level = level
        mixer.setLevel(level, forInput: id)
        scheduleAutosave()
    }

    /// Sets one channel strip's pan position, applied to the program mix
    /// from the next mix tick. Gesture-rate like
    /// ``setStripLevel(_:forStrip:)``, so it reports nothing itself — the
    /// pan slider's drag-end `tap` event carries the observability
    /// (EVENTS.md) — and the autosave is debounced like the level's. Pan
    /// never touches device lifecycle, so unlike a mute there is no
    /// reconfigure pass.
    ///
    /// - Parameters:
    ///   - pan: The strip's pan position, `-1` (hard left) to `1` (hard
    ///     right).
    ///   - id: The strip's input id.
    func setStripPan(_ pan: Double, forStrip id: InputID) {
        guard let index = mixerStrips.firstIndex(where: { $0.id == id }) else { return }
        mixerStrips[index].pan = pan
        mixer.setPan(pan, forInput: id)
        scheduleAutosave()
    }

    /// Mutes or unmutes one channel strip. Beyond silencing the channel in
    /// the mix, the app ties the strip's device lifecycle to its mute:
    /// muting stops the device (the microphone indicator goes dark — a muted
    /// microphone is not captured), unmuting starts it again, with the mix
    /// carrying silence for that strip either way until frames flow
    /// (ARCHITECTURE.md, "The audio mixer").
    ///
    /// - Parameters:
    ///   - isMuted: Whether the strip is muted.
    ///   - id: The strip's input id.
    func setStripMuted(_ isMuted: Bool, forStrip id: InputID) async {
        guard let index = mixerStrips.firstIndex(where: { $0.id == id }) else { return }
        mixerStrips[index].isMuted = isMuted
        mixer.setMuted(isMuted, forInput: id)
        scheduleAutosave()
        await reconfigureAudio()
    }

    /// Turns one channel strip's **audio follows video** on or off
    /// (GLOSSARY.md, "Audio follows video"): with it on, the strip feeds the
    /// program mix only while its input is in the program shot. Applied to
    /// the mix at once, as a cut — turning it on for a strip whose input is
    /// off program takes that strip's sound off air, turning it off brings
    /// it back — and persisted in the active preset like every strip edit.
    /// Device lifecycle is untouched, so there is no reconfigure pass; the
    /// toggle's own `tap` carries the observability.
    ///
    /// - Parameters:
    ///   - followsProgram: Whether the strip's audio follows video.
    ///   - id: The strip's input id.
    func setStripFollowsProgram(_ followsProgram: Bool, forStrip id: InputID) {
        guard let index = mixerStrips.firstIndex(where: { $0.id == id }) else { return }
        mixerStrips[index].followsProgram = followsProgram
        syncProgramPresence()
        scheduleAutosave()
    }

    /// The discovered audio inputs that are **not** on the mixer, in listing
    /// order — what the Add Channel menu offers. An absent device that is
    /// not yet a strip cannot be offered: the list draws from discovery.
    var audioInputsOffMixer: [InputChoice] {
        audioInputs.filter { !isOnMixer($0.id) }
    }

    /// Whether an input has a channel strip on the mixer — dormant or not.
    ///
    /// - Parameter id: The input to ask about.
    /// - Returns: Whether the active preset's mix holds a strip for it.
    func isOnMixer(_ id: InputID) -> Bool {
        mixerStrips.contains { $0.id == id }
    }

    /// Whether an input's strip is feeding the program mix right now: on the
    /// mixer, unmuted, its device discovered (a dormant strip contributes
    /// silence), and — when its audio follows video — its input on program
    /// (an AFV strip off program contributes nothing). What lights an audio
    /// row's program tally in the sidebar.
    ///
    /// - Parameter id: The input to ask about.
    /// - Returns: Whether the input is live in the mix.
    func isLiveInMix(_ id: InputID) -> Bool {
        mixerStrips.contains { $0.id == id && !$0.isMuted && $0.isPresent(onProgram: programInputIDs) }
            && audioInputs.contains { $0.id == id }
    }

    /// Adds a channel strip for a discovered audio input, at the end of the
    /// row, **muted** at unity and centered (``MixerStrip/added(_:)``):
    /// adding a channel is a patch, not opening the fader, so it starts no
    /// device and changes nothing on air. Persisted in the active preset
    /// like any strip edit. An input already on the mixer, or one discovery
    /// does not hold, changes nothing. The control that called it reports
    /// its own `tap` (ARCHITECTURE.md, "Per-strip routing", the amendment of
    /// 2026-11-07).
    ///
    /// - Parameter id: The audio input to add.
    /// - Returns: Whether a strip was added.
    @discardableResult
    func addStrip(for id: InputID) -> Bool {
        guard !isOnMixer(id), let input = audioInputs.first(where: { $0.id == id }) else { return false }
        // An audio file produces no video, so it is in no shot and its strip
        // must not follow one (``MixerStrip/defaultFollowsProgram(for:hasPicture:)``).
        let hasPicture = videoInputs.contains { $0.id == id }
        mixerStrips.append(MixerStrip.added(input, hasPicture: hasPicture))
        scheduleAutosave()
        return true
    }

    /// Removes a channel strip from the mixer — and so from the active
    /// preset's authored channels, with its level, pan, and effect chain.
    /// A running device stops (the audio pass reports `input.stopped` with
    /// reason `stripMutedOrRemoved`), and the mixer drops the strip from
    /// the next mix tick. The input itself stays discovered and listed in
    /// the sidebar, ready to be added again.
    ///
    /// - Parameter id: The strip's input id.
    func removeStrip(_ id: InputID) async {
        guard let index = mixerStrips.firstIndex(where: { $0.id == id }) else { return }
        mixerStrips.remove(at: index)
        scheduleAutosave()
        await reconfigureAudio()
    }

    /// Adds the muted strip for a **video file with sound** just placed in a
    /// shot, when it is not on the mixer yet (``MixerStrip/mediaStrip(for:strips:discovered:)``).
    /// Putting the file in a shot is the use, so its sound needs no separate
    /// add; removing the layer later leaves the strip, since its settings
    /// are the operator's work. Called from every edit that binds an input
    /// to a shot.
    ///
    /// - Parameter input: The input just placed in a shot.
    func addStripForMediaSound(_ input: InputID) {
        guard let strip = MixerStrip.mediaStrip(for: input, strips: mixerStrips, discovered: audioInputs) else {
            return
        }
        mixerStrips.append(strip)
        scheduleAutosave()
    }
}
