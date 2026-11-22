//
//  EngineModel+Multiview.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import Foundation
import TingraAudio
import TingraComposition
import TingraPlugInKit

/// The monitors' latest frames, and the tally that marks what is on program and preview.
extension EngineModel {
    /// One input's latest frame, for a multiview tile to draw.
    ///
    /// A straight forward to ``Compositor/latestFrame(forInput:)`` — the
    /// slot the compositor already holds, shared read-only for one draw
    /// (ARCHITECTURE.md, "Frame ownership across the `Input` seam", clause
    /// 4). The tile pulls it on its own draw at display cadence, so a
    /// multiview window nobody has open costs the engine nothing at all.
    ///
    /// - Parameter id: The input to read.
    /// - Returns: The input's most recent pixel buffer, or nil when it is
    ///   not running or has not delivered one yet.
    func latestFrame(forInput id: InputID) -> CVPixelBuffer? {
        compositor.latestFrame(forInput: id)?.pixelBuffer
    }

    /// The stamp of one input's latest frame, for a monitor to tell a new
    /// frame from the one it last drew (``MonitorFrameStamp``) — read from
    /// the same slot as ``latestFrame(forInput:)``, holding nothing.
    ///
    /// - Parameter id: The input to read.
    /// - Returns: The stamp, or nil when the input is not running or has
    ///   not delivered a frame yet.
    func latestFrameStamp(forInput id: InputID) -> MonitorFrameStamp? {
        compositor.latestFrame(forInput: id).map(MonitorFrameStamp.init)
    }

    /// The latest frame of every input a shot's layers are bound to, keyed
    /// by input — the `frames` a renderer composes from — read from the
    /// compositor's read-only latest-wins slots (a share, never a copy;
    /// ownership clause 4). An input that has not delivered is absent, so
    /// its layer contributes nothing, exactly as on program. For the shot
    /// bank's tiles (``ShotThumbnailSource``).
    ///
    /// - Parameter shot: The shot whose layers' inputs to read.
    /// - Returns: The frames, keyed by input.
    func latestFrames(for shot: Shot) -> [InputID: CapturedFrame] {
        var frames: [InputID: CapturedFrame] = [:]
        for layer in shot.layers where frames[layer.input] == nil {
            frames[layer.input] = compositor.latestFrame(forInput: layer.input)
        }
        return frames
    }

    /// Re-reads the tally from the compositor: which inputs are on program,
    /// and which are on the staged shot.
    ///
    /// Called from every place the app changes the program, the staged
    /// shot, or a shot's layer bindings — the same call sites that already
    /// mirror ``Compositor/activeShotID``/``Compositor/previewShotID`` back
    /// from the compositor, so the tally is read from the engine rather
    /// than second-guessed here. The one change the app cannot observe this
    /// way is a transition *finishing*, which ``scheduleTallyRefresh(after:)``
    /// covers.
    ///
    /// It is also the choke point for **audio follows video**: every change
    /// to what is on program passes through here, so it brings the mixer's
    /// program presence in line too (``syncProgramPresence(rampDuration:)``)
    /// — ramping over the take's transition, or as a cut for every other
    /// change (ARCHITECTURE.md, "Audio follows video").
    ///
    /// - Parameter transition: The transition the program changed with — a
    ///   take's; every other change is a cut (the default).
    func syncTally(changingProgramWith transition: Transition = .cut) {
        programInputIDs = compositor.programInputIDs
        previewInputIDs = Set(compositor.previewShot?.layers.map(\.input) ?? [])
        syncProgramPresence(rampDuration: transition.duration)
    }

    /// Sets the mixer's **program presence** for every strip from the
    /// inputs in the program shot — the app half of audio follows video,
    /// since `TingraAudio` knows nothing of shots (ARCHITECTURE.md, "Audio
    /// follows video").
    ///
    /// Reads the **incoming** program shot (``Compositor/programShot``), not
    /// ``programInputIDs``, which unions the outgoing shot while a
    /// transition runs: the outgoing shot's AFV strips ramp down while the
    /// incoming shot's ramp up, and an input in both stays up
    /// (``MixerStrip/programPresence(of:onProgram:)``). Strips with AFV off
    /// are always present. Presence is a latch in the mixer, so re-applying
    /// what is already in effect — the tally refresh at the end of a
    /// transition, say — never disturbs a crossfade in flight.
    ///
    /// - Parameter rampDuration: The crossfade length in seconds; `0` (the
    ///   default) is a cut.
    func syncProgramPresence(rampDuration: TimeInterval = 0) {
        let programInputs = Set(compositor.programShot.layers.map(\.input))
        for (id, present) in MixerStrip.programPresence(of: mixerStrips, onProgram: programInputs) {
            mixer.setProgramPresence(present, forInput: id, rampDuration: rampDuration)
        }
    }

    /// Schedules the one tally refresh the app has no other way to learn
    /// about: the moment a transition completes and the outgoing shot's
    /// inputs stop being on air.
    ///
    /// Every other tally change follows an operator action the model
    /// already handles, but a transition ends on a compositor tick with
    /// nothing observable attached — so a take schedules a single refresh
    /// for its own known duration. This is **not** a poll: it is
    /// one shot, derived from the duration the take was made with, and a
    /// second take supersedes it by cancelling the first. A cut schedules
    /// nothing — it has already landed.
    ///
    /// - Parameter transition: The transition the take was made with.
    func scheduleTallyRefresh(after transition: Transition) {
        tallyRefreshTask?.cancel()
        let duration: TimeInterval
        switch transition {
        case .cut: return
        case .dissolve(let seconds): duration = seconds
        case .wipe(_, let seconds): duration = seconds
        case .shader(_, let seconds): duration = seconds
        }
        // A tick of margin, so the refresh lands after the compositor's
        // final blend tick rather than a frame before it: a tally that
        // stays lit a frame too long is honest, one that darkens early is
        // not.
        let margin = 1.0 / Double(format.frameRate)
        tallyRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, duration) + margin))
            guard !Task.isCancelled else { return }
            self?.syncTally()
        }
    }
}
