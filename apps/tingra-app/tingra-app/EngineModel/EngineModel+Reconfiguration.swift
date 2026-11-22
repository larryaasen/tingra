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
    /// reference, stops what they no longer do. Called at boot and after
    /// anything that can change that set. Coalesces: one pass runs at a time,
    /// and a request arriving mid-pass makes it loop once more with the
    /// latest state, so a burst never races the input start/stop.
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

    /// One reconfigure pass: starts newly needed inputs, stops unneeded ones,
    /// and hands the active set to the compositor. The first pass also
    /// establishes the session preset, seeding a fresh project when no file
    /// supplied one.
    ///
    /// An input that cannot start is reported on the bus and left out; one
    /// that started silent last time is skipped with `input.skipped` until
    /// something that could change it happens (``silentInputs``). The running
    /// set is every input the active preset's shots reference, transient
    /// shots included, plus whatever the program is holding. Nothing runs for
    /// monitoring alone (ARCHITECTURE.md, "The shot bank").
    private func applyConfiguration() async {
        let isFirstPass = !hasAppliedConfiguration

        // A loaded project's preset goes into the compositor before any input
        // is waited on: its shots render whichever referenced inputs are
        // running, and waiting would put a slow device's verification window
        // between launch and the first program frame. Only a fresh project's
        // seed waits, because it is laid out around the devices that started.
        let presetEstablishedEarly = isFirstPass && hasSessionPreset
        if presetEstablishedEarly { establishSessionPreset() }

        var desired: [InputID: any Input] = [:]
        // A fresh project has no shots to say what should run, so its first
        // pass starts the first discovered display and camera for the seed.
        if isFirstPass, !hasSessionPreset {
            for id in [displays.first?.id, cameras.first?.id].compactMap({ $0 }) {
                if let input = await registry.input(withID: id) {
                    desired[id] = input
                }
            }
        }
        // Keep running every input the active preset's shots reference, plus
        // whatever the program is rendering: after a preset switch that can
        // be a held snapshot from outside the pool (``switchPreset(to:)``).
        var referenced = Set(shots.flatMap { $0.layers.map(\.input) })
        referenced.formUnion(compositor.programShot.layers.map(\.input))
        for id in referenced where desired[id] == nil {
            if let input = await registry.input(withID: id) {
                desired[id] = input
            }
        }

        // Which inputs still exist, so a stop can say why: one the registry
        // no longer holds was unplugged, one it still holds is unreferenced.
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
            // silent-input skip only concerns starting a device.
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
        // so the compositor's set is republished per start and reported once.
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
    /// the mixer. Coalesced like ``reconfigure()``, so a burst of mute
    /// toggles never races the device lifecycle.
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
    /// desired set, and anything else stops. An input that cannot start is
    /// reported on the bus and left out; its strip stays on the panel and
    /// contributes silence.
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
            // A muted or removed strip releases its device, so the capture
            // indicator goes out (the honest-microphone policy).
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

        // The mixer gets every strip whose device is running.
        let strips = mixerStrips.compactMap { strip -> ChannelStrip? in
            guard let input = activeAudioInputs[strip.id] else { return nil }
            return ChannelStrip(input: input, level: strip.level, pan: strip.pan, isMuted: strip.isMuted)
        }
        // Program presence first (audio follows video): it is keyed apart
        // from the strips, so no tick mixes a newly running AFV strip whose
        // input is off program, and a strip whose AFV resolved since the
        // last pass picks it up here.
        syncProgramPresence()
        mixer.setChannelStrips(strips)
        // Each running strip's authored chain is instantiated fresh. A
        // reconfigure is rare, so losing the chain's few milliseconds of
        // filter memory is inaudible; parameter drags use the in-place path.
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
    /// list: the one place the active set becomes the program's. Silent: a
    /// pass calls it per started input and reports the set once with
    /// ``reportActiveInputs()``. Multiview tiles what is running and produces
    /// video, never what is merely discovered, in a stable name order so a
    /// tile does not jump when another device connects (ARCHITECTURE.md,
    /// "The `Input` media capability").
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
    /// moment it is proven live. Concurrently, never one after another: a
    /// device whose start stalls (a camera timing out for ten seconds) would
    /// otherwise hold every other input, and the active preset, behind it.
    ///
    /// Each outcome is reported on the bus in completion order, and
    /// `onStarted` runs in that order, so a caller can put a fast device into
    /// the program while a slow one is still verifying. An input that cannot
    /// start is reported as an `input.start` error and left out; one that
    /// started but stayed silent is also remembered in ``silentInputs``, so
    /// the next pass does not pay its verification window again.
    ///
    /// - Parameters:
    ///   - inputs: The inputs to start, by identifier.
    ///   - onStarted: Called on the main actor for each input that started,
    ///     before its `input.started` event.
    ///   - onRefused: Called on the main actor for each input that could not
    ///     start, before its `input.start` error, so the caller can drop its
    ///     claim (``InputClaims``).
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

    /// Starts the inputs a permission grant has just unblocked. A denied
    /// input stays out of the active set until a pass tries it again, so
    /// without this a grant made in System Settings would appear to do
    /// nothing. The video pass covers the camera and Screen Recording grants,
    /// the audio pass the microphone; both coalesce and skip an input
    /// already running.
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
    /// reports its first audio (`input.format` with `kind: application`).
    /// macOS has no read for that permission, so the audio arriving is the
    /// only proof (ARCHITECTURE.md, "Application audio", A10).
    ///
    /// - Parameter event: An event drained from the bus.
    func handleApplicationAudioArrived(_ event: EventBusEvent) {
        guard event.name == "input.format",
            event.params?["kind"].flatMap(Self.stringValue) == InputKind.application.rawValue
        else { return }
        permissions.noteGranted(.systemAudioRecording)
    }

    /// Releases an input whose capture session died after a successful
    /// start, on its `input.runtimeError` event. The input has already torn
    /// its session down (``CameraInput``); dropping it from the active set
    /// lets the next reconfigure pass try the device again, and takes its
    /// frozen last frame out of the program. No automatic retry: a device
    /// that dies on every start would loop.
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
