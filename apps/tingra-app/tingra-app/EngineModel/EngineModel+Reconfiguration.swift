//
//  EngineModel+Reconfiguration.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraCapturePlugIns
import TingraComposition
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// Starting and stopping inputs so the running set matches what the shots and the mixer need.
extension EngineModel {
    /// Brings the running inputs in line with the show: starts what its shots
    /// reference, stops what they no longer do.
    ///
    /// Called once at boot and after anything that can change that set — an
    /// edit binding a new input, a device event, a permission grant. It
    /// **coalesces**: only one pass runs at a time (the pass suspends at
    /// `input.start()`/`stop()`), and a request arriving mid-pass makes the
    /// running pass loop once more with the latest state — so a burst of
    /// requests never overlaps and races the input start/stop.
    func reconfigure() async {
        reconfigureRequested = true
        guard !reconfiguring else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        while reconfigureRequested {
            reconfigureRequested = false
            await applyConfiguration()
        }
    }

    /// One reconfigure pass: starts newly needed inputs, stops no-longer-needed
    /// ones, and hands the active set to the compositor; on the first pass it
    /// also establishes the session preset (loading it into the compositor,
    /// seeding a fresh project when no file supplied one).
    ///
    /// An input that cannot start (authorization denied, device gone) is
    /// reported on the bus and left out — the program keeps showing whatever
    /// else is available, never a failure state. One that started silent last
    /// time is skipped, with an `input.skipped` event, until something that
    /// could have changed it happens (``silentInputs``).
    ///
    /// The running set is every input the active preset's shots reference —
    /// transient shots included, so the shot the operator is looking at on
    /// preview has its input running — plus whatever the program is holding,
    /// and on a fresh project's first pass the first discovered display and
    /// camera the seed is laid out around. Nothing runs for monitoring alone:
    /// the shot bank's
    /// thumbnails read inputs the show already references, and the multiview
    /// window tiles only what is running (ARCHITECTURE.md, "The shot bank").
    private func applyConfiguration() async {
        let isFirstPass = !hasAppliedConfiguration

        // A loaded project's preset goes into the compositor **before** any
        // input is waited on: the shots reference inputs by id and render
        // whatever of them is running, so nothing about the preset depends on
        // which starts succeed. Waiting would put the whole verification
        // window — ten seconds for a camera macOS lists but has switched off
        // — between launch and the first program frame (observed 2026-09-06,
        // lid closed: the preset loaded at 6.3 s while every available input
        // was live at 1.5 s). Only a fresh project's seed still waits, because
        // its shots are laid out around which of its devices actually started.
        let presetEstablishedEarly = isFirstPass && hasSessionPreset
        if presetEstablishedEarly { establishSessionPreset() }

        var desired: [InputID: any Input] = [:]
        // A fresh project has no shots yet to say what should run, so its
        // first pass starts the first discovered display and camera — what
        // the seed is laid out around, once it knows which of them started.
        if isFirstPass, !hasSessionPreset {
            for id in [displays.first?.id, cameras.first?.id].compactMap({ $0 }) {
                if let input = await registry.input(withID: id) {
                    desired[id] = input
                }
            }
        }
        // Keep every input the active preset's layer trees reference running
        // — plus whatever the program is actually rendering, which after a
        // preset switch can be a held snapshot from outside the loaded pool
        // (see ``switchPreset(to:)``).
        var referenced = Set(shots.flatMap { $0.layers.map(\.input) })
        referenced.formUnion(compositor.programShot.layers.map(\.input))
        for id in referenced where desired[id] == nil {
            if let input = await registry.input(withID: id) {
                desired[id] = input
            }
        }

        // Which inputs still exist at all, so a stop can say *why*. An input
        // the registry no longer holds was unplugged; one it still holds is
        // merely no longer referenced. Reporting both as "unreferenced" was a
        // lie the moment the app started reacting to disconnections.
        let registeredIDs = Set(await registry.allInputs.map(\.id))
        for (id, input) in activeInputs where desired[id] == nil {
            activeInputs[id] = nil
            // A video file with sound that an unmuted strip still hears keeps
            // running for the strip; only the last claim stops it.
            guard inputClaims.release(id, by: .picture) else { continue }
            await input.stop()
            eventBus.event(
                "input.stopped",
                domain: .capture,
                params: [
                    "id": .string(id.rawValue),
                    "reason": .string(registeredIDs.contains(id) ? "unreferenced" : "disconnected"),
                ]
            )
        }
        var pending: [InputID: any Input] = [:]
        for (id, input) in desired where activeInputs[id] == nil {
            // An input a strip already runs joins the program as it is; the
            // silent-input skip is about starting a device, so it does not
            // apply.
            if !inputClaims.isClaimed(id, by: .sound), silentInputs.contains(id) {
                eventBus.event(
                    "input.skipped",
                    domain: .capture,
                    params: ["id": .string(id.rawValue), "reason": .string("silentSinceLastAttempt")]
                )
                continue
            }
            if inputClaims.claim(id, by: .picture) {
                pending[id] = input
            } else {
                activeInputs[id] = input
            }
        }
        // Each input joins the program the moment its first frame is proven,
        // not when the slowest device in the pass gives up: the compositor's
        // set is republished per start, and reported once at the end.
        await startConcurrently(pending) { [self] id, input in
            activeInputs[id] = input
            publishActiveInputs()
        } onRefused: { [self] id in
            _ = inputClaims.release(id, by: .picture)
        }
        publishActiveInputs()
        reportActiveInputs()
        if isFirstPass {
            hasAppliedConfiguration = true
            if !presetEstablishedEarly { establishSessionPreset() }
        }
    }

    /// Applies the current strips to the audio engine: starts newly unmuted
    /// strips' devices, stops newly muted ones, and hands the running set to
    /// the mixer. Coalesced exactly like ``reconfigure()`` — the pass
    /// suspends at `input.start()`/`stop()`, so a burst of mute toggles
    /// never overlaps and races the device lifecycle.
    func reconfigureAudio() async {
        audioReconfigureRequested = true
        guard !reconfiguringAudio else { return }
        reconfiguringAudio = true
        defer { reconfiguringAudio = false }
        while audioReconfigureRequested {
            audioReconfigureRequested = false
            await applyAudioConfiguration()
        }
    }

    /// One audio reconfigure pass: the unmuted strips' devices are the
    /// desired set; anything else stops. An input that cannot start
    /// (authorization denied, device gone) is reported on the bus and left
    /// out — its strip stays on the panel and simply contributes silence,
    /// never a failure state.
    private func applyAudioConfiguration() async {
        var desired: [InputID: any Input] = [:]
        for strip in mixerStrips where !strip.isMuted {
            if let input = await registry.input(withID: strip.id) {
                desired[strip.id] = input
            }
        }

        for (id, input) in activeAudioInputs where desired[id] == nil {
            activeAudioInputs[id] = nil
            // A video file with sound that a layer still shows keeps running
            // for the layer; its strip simply leaves the mix.
            guard inputClaims.release(id, by: .sound) else { continue }
            await input.stop()
            // An audio input stops here only because its strip is muted or
            // gone — the honest-microphone policy, where a muted strip
            // releases the device so its capture indicator goes out.
            eventBus.event(
                "input.stopped",
                domain: .capture,
                params: ["id": .string(id.rawValue), "reason": .string("stripMutedOrRemoved")]
            )
        }
        var pending: [InputID: any Input] = [:]
        for (id, input) in desired where activeAudioInputs[id] == nil {
            // An input a layer already runs joins the mix as it is.
            if inputClaims.claim(id, by: .sound) {
                pending[id] = input
            } else {
                activeAudioInputs[id] = input
            }
        }
        await startConcurrently(pending) { [self] id, input in
            activeAudioInputs[id] = input
        } onRefused: { [self] id in
            _ = inputClaims.release(id, by: .sound)
        }

        // The mixer gets every strip whose device is running, with its
        // current level, pan, and mute — the engine-side strips of the mix.
        let strips = mixerStrips.compactMap { strip -> ChannelStrip? in
            guard let input = activeAudioInputs[strip.id] else { return nil }
            return ChannelStrip(input: input, level: strip.level, pan: strip.pan, isMuted: strip.isMuted)
        }
        // Program presence first (audio follows video): it is keyed apart
        // from the strips, so setting it before they join the mix means no
        // tick ever mixes a newly running AFV strip whose input is off
        // program — and a strip whose AFV resolved since the last pass (a
        // device discovered, a preset adopted) picks it up here.
        syncProgramPresence()
        mixer.setChannelStrips(strips)
        // Each running strip's authored chain is instantiated fresh and
        // handed to its mixer channel (a reconfigure is rare — a mute
        // toggle, a preset switch — so re-instantiating the chain's few
        // milliseconds of filter memory is inaudible; parameter drags go
        // through the in-place path instead).
        for strip in mixerStrips where activeAudioInputs[strip.id] != nil && !strip.effects.isEmpty {
            mixer.setEffects(await makeEffectChain(strip.effects), forInput: strip.id)
        }
        eventBus.event(
            "mixer.channels",
            domain: .audio,
            params: ["ids": .string(activeAudioInputs.keys.map(\.rawValue).sorted().joined(separator: ","))]
        )
    }

    /// Hands the running input set to the compositor and the multiview
    /// list — the one place the active set becomes the program's, so a pass,
    /// a per-start publish, and a mid-show release cannot do it differently.
    /// Silent: a pass calls this once per started input and reports the set
    /// once at the end with ``reportActiveInputs()``.
    ///
    /// Multiview tiles exactly what is running — never what is merely
    /// discovered — in a stable name order, so a tile does not jump when
    /// another device connects. A tile shows picture, so the filter is the
    /// media question: everything running that produces video, which now
    /// includes the video generators (ARCHITECTURE.md, "The `Input` media
    /// capability").
    private func publishActiveInputs() {
        compositor.setInputs(Array(activeInputs.values))
        multiviewInputs =
            activeInputs.values
            .filter { $0.media.contains(.video) }
            .map { InputChoice(id: $0.id, name: $0.name, kind: $0.kind) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reports the compositor's current input set on the bus — once per
    /// pass, after every start has landed, so the log carries the settled set
    /// rather than one line per device.
    private func reportActiveInputs() {
        eventBus.event(
            "compositor.inputs",
            domain: .composition,
            params: ["ids": .string(activeInputs.keys.map(\.rawValue).sorted().joined(separator: ","))]
        )
    }

    /// Starts every given input at once, handing each one to the caller the
    /// moment it is proven live.
    ///
    /// **Concurrently, never one after another** — the sequential loop this
    /// replaces let a single device stall the whole pass. Observed 2026-09-06:
    /// a USB camera whose stream start timed out inside IOKit held
    /// `input.start()` for ten seconds, and because every other input waited
    /// behind it, the compositor received no input set and the active preset
    /// did not load until that timeout expired, while the two Continuity
    /// Cameras that had already started backed up their CoreMedia I/O queues
    /// for the duration. A device's start now costs only that device.
    ///
    /// Each outcome is reported on the bus as it lands, in completion order,
    /// so the log's timestamps say when each device actually came up, and
    /// `onStarted` runs in that same order — which is what lets a caller put
    /// a fast device into the program while a slow one is still verifying.
    /// An input that cannot start (authorization denied, device gone, a
    /// session that reported a runtime error) is reported as an `input.start`
    /// error and left out — the caller keeps whatever else is available,
    /// never a failure state. One that started but stayed silent is reported
    /// the same way and remembered in ``silentInputs``, so the next pass does
    /// not pay its verification window again.
    ///
    /// - Parameters:
    ///   - inputs: The inputs to start, by identifier.
    ///   - onStarted: Called on the main actor for each input that started,
    ///     before its `input.started` event.
    ///   - onRefused: Called on the main actor for each input that could not
    ///     start, before its `input.start` error, so the caller can drop the
    ///     claim it made (``InputClaims``).
    private func startConcurrently(
        _ inputs: [InputID: any Input],
        onStarted: (InputID, any Input) -> Void,
        onRefused: (InputID) -> Void
    ) async {
        await withTaskGroup(of: (InputID, Result<any Input, any Error>).self) { group in
            for (id, input) in inputs {
                group.addTask {
                    do {
                        try await input.start()
                        return (id, .success(input))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, outcome) in group {
                switch outcome {
                case .success(let input):
                    onStarted(id, input)
                    eventBus.event(
                        "input.started",
                        domain: .capture,
                        params: ["id": .string(id.rawValue), "name": .string(input.name)]
                    )
                case .failure(let error):
                    onRefused(id)
                    if case CaptureInputError.startedSilent = error { silentInputs.insert(id) }
                    eventBus.error(
                        "input.start",
                        domain: .capture,
                        params: [
                            "id": .string(id.rawValue),
                            "error": .string(String(describing: error)),
                        ]
                    )
                }
            }
        }
    }

    /// Starts the inputs a permission grant has just unblocked.
    ///
    /// A display input denied Screen Recording at boot stays out of the
    /// active set until a reconfigure pass tries it again, and before this
    /// existed that pass only came along with a picker change or a device
    /// event — so a grant made in System Settings looked like it had done
    /// nothing (observed 2026-09-06). The video pass covers the camera and
    /// Screen Recording grants; the audio pass covers the microphone, whose
    /// strips start their devices. Both coalesce, and both skip an input
    /// already running, so calling this with a grant that changed nothing
    /// costs a registry read.
    ///
    /// - Parameter granted: The permissions that newly became granted, as
    ///   ``PermissionsModel/refresh()`` reports them; an empty set does
    ///   nothing.
    func applyNewlyGranted(_ granted: Set<AuthorizationPermission>) async {
        guard !granted.isEmpty else { return }
        // A grant is a change worth retrying a silent input for.
        silentInputs.removeAll()
        if granted.contains(.camera) || granted.contains(.screenRecording) {
            await reconfigure()
        }
        if granted.contains(.microphone) {
            await reconfigureAudio()
        }
    }

    /// Records System Audio Recording as granted when an application input
    /// reports its first audio — the `input.format` event with `kind:
    /// application`. macOS has no read for that permission, so the audio
    /// arriving is the only proof there is (ARCHITECTURE.md, "Application
    /// audio", A10).
    ///
    /// - Parameter event: An event drained from the bus.
    func handleApplicationAudioArrived(_ event: EventBusEvent) {
        guard event.name == "input.format",
            event.params?["kind"].flatMap(Self.stringValue) == InputKind.application.rawValue
        else { return }
        permissions.noteGranted(.systemAudioRecording)
    }

    /// Releases an input whose capture session died after a successful
    /// start, on its `input.runtimeError` event.
    ///
    /// The input has already torn its session down and finished its frame
    /// stream by the time the event is on the bus (``CameraInput``); what
    /// remains is the engine's bookkeeping. Dropping it from the active set
    /// is what lets the next reconfigure pass — a picker change, a device
    /// event — try the device again, and handing the compositor the reduced
    /// set is what takes the frozen last frame out of the program rather
    /// than leaving a dead input rendering. No automatic retry here: a
    /// device that dies on every start would otherwise loop, and the pass
    /// that retries it is one the operator or a device event asks for.
    ///
    /// - Parameter event: An event drained from the bus.
    func handleInputRuntimeError(_ event: EventBusEvent) async {
        guard event.name == "input.runtimeError", let rawID = event.params?["id"].flatMap(Self.stringValue) else {
            return
        }
        let id = InputID(rawValue: rawID)
        // Both passes let go at once, and the input is stopped once: its
        // capture is already gone, so the next claim must start it afresh.
        let shown = activeInputs.removeValue(forKey: id)
        let heard = activeAudioInputs.removeValue(forKey: id)
        inputClaims.forget(id)
        if let input = shown ?? heard {
            await input.stop()
        }
        if shown != nil {
            publishActiveInputs()
            reportActiveInputs()
        }
        if heard != nil {
            await reconfigureAudio()
        }
        eventBus.event(
            "input.stopped",
            domain: .capture,
            params: ["id": .string(rawID), "reason": .string("runtimeError")]
        )
    }
}
