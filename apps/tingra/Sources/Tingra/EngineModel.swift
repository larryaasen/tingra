//
//  EngineModel.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreVideo
import Observation
import TingraCapturePlugIns
import TingraComposition
import TingraEventBus
import TingraGeneratorPlugIns
import TingraHost
import TingraPlugInKit

/// The app's engine model: the one `@Observable` that boots the host,
/// activates the first-party plug-ins, and drives the compositor for the
/// on-screen program preview (roadmap step 6).
///
/// It mirrors the CLI's engine wiring (an `InputRegistry`, a `HostClock`, a
/// `PlugInLoader` activating the same plug-ins through the same
/// `PlugInContext`) but ends in the ``Compositor`` and an `MTKView` rather
/// than a streaming service — the app takes shape around the same proven
/// engine, not a fork of it (GLOSSARY.md, "Engine").
///
/// `@MainActor`, per the project's `@Observable` rule: the UI reads its
/// published input lists and selection directly, and every plug-in and
/// compositor call is made from here.
@MainActor
@Observable
final class EngineModel {
    /// One selectable input (a camera or a display) as the pickers show it.
    struct InputChoice: Identifiable, Hashable {
        /// The input's stable identifier.
        let id: InputID

        /// The user-facing name.
        let name: String
    }

    /// The discovered cameras, for the camera picker.
    private(set) var cameras: [InputChoice] = []

    /// The discovered displays, for the display picker.
    private(set) var displays: [InputChoice] = []

    /// The chosen camera, or nil for none. The display is the full-frame
    /// background; the camera composites over it as a picture-in-picture.
    var selectedCameraID: InputID?

    /// The chosen display, or nil for none.
    var selectedDisplayID: InputID?

    /// The shots the current selection makes available, in switcher order —
    /// what the shot switcher lists (roadmap step 7).
    private(set) var shots: [Shot] = []

    /// The id of the shot currently on program, so the switcher can highlight
    /// it. `nil` when there are no shots (no input selected).
    private(set) var activeShotID: ShotID?

    /// Whether the next shot switcher tap dissolves rather than cuts
    /// (GLOSSARY.md, "Transition"). A plain toggle bound from `ContentView`;
    /// the switcher itself still always reports the cut/dissolve choice it
    /// used, never guesses at intent.
    var useDissolveTransition = false

    /// The latest program frame, handed to the preview view to draw. Held
    /// in a plain relay (not observed) so the ~30 fps program does not churn
    /// SwiftUI — the `MTKView` samples it at display rate (CLOCK.md).
    @ObservationIgnored let programRelay = ProgramFrameRelay()

    /// The host event bus. In this dev scaffold its events are printed to
    /// stdout (the Xcode console) via ``ConsoleEventSink`` rather than routed
    /// to OSLog, which does not surface in Xcode's debug console.
    ///
    /// Not `private`: every `tap` event is reported by the UI code that
    /// executes the action (a `Button`'s action closure, a picker's
    /// `onChange`), not by the model on the view's behalf — so `ContentView`
    /// calls `model.eventBus.tap(...)` directly (EVENTS.md, "The `tap`
    /// convention").
    @ObservationIgnored let eventBus = EventBus()

    /// The master clock (see CLOCK.md).
    @ObservationIgnored private let clock = HostClock()

    /// The input registry the plug-ins register into.
    @ObservationIgnored private let registry = InputRegistry()

    /// The program geometry and rate.
    @ObservationIgnored private let format = ProgramFormat(width: 1920, height: 1080, frameRate: 30)

    /// The stable id of the app's single built-in preset. A preset switcher
    /// and multiple presets arrive in a later iteration; the internal name is
    /// not yet surfaced, so it stays unlocalized for now.
    @ObservationIgnored private let presetID = PresetID(rawValue: "default")

    /// The compositor producing the program frames.
    @ObservationIgnored private lazy var compositor = Compositor(
        clock: clock,
        format: format,
        eventBus: eventBus
    )

    /// The console sink's drain task, retained so the sink keeps consuming
    /// the bus for the app's lifetime.
    @ObservationIgnored private var logSinkTask: Task<Void, Never>?

    /// The inputs currently started, keyed by id, so selection changes start
    /// and stop only what actually changed.
    @ObservationIgnored private var activeInputs: [InputID: any Input] = [:]

    /// The task draining the compositor's program stream into the relay.
    @ObservationIgnored private var programTask: Task<Void, Never>?

    /// Whether ``start()`` has run, so it boots the engine once.
    @ObservationIgnored private var started = false

    /// Whether a ``reconfigure()`` pass is currently running. `reconfigure()`
    /// suspends at `input.start()`/`stop()`, so without this guard the
    /// startup selection changes (two `onChange` handlers) and the explicit
    /// boot call would interleave and race the input start/stop.
    @ObservationIgnored private var reconfiguring = false

    /// Set whenever a reconfigure is requested while one is already running,
    /// so the running pass loops once more and applies the latest selection —
    /// coalescing a burst of requests into the minimum number of passes.
    @ObservationIgnored private var reconfigureRequested = false

    /// Creates the model. The engine boots in ``start()`` when the window
    /// appears, not here.
    init() {}

    /// Boots the engine: attaches the log sink, activates the capture and
    /// generator plug-ins, discovers inputs, starts the compositor, and
    /// begins feeding the preview. Idempotent.
    func start() async {
        guard !started else { return }
        started = true

        // Print events to the Xcode console (stdout) rather than OSLog, which
        // does not appear in Xcode's debug console (see ``ConsoleEventSink``).
        logSinkTask = eventBus.attach(ConsoleEventSink())
        let context = PlugInContext(
            eventBus: eventBus,
            clock: clock,
            inputs: registry,
            outputs: UnusedOutputRegistering(),
            tools: UnusedToolRegistering()
        )
        await PlugInLoader().activate(
            [AVFoundationCapturePlugIn(), ScreenCaptureKitCapturePlugIn(), GeneratorPlugIn()],
            in: context
        )

        let inputs = await registry.allInputs
        cameras = inputs.filter { $0.kind == .camera }.map { InputChoice(id: $0.id, name: $0.name) }
        displays = inputs.filter { $0.kind == .display }.map { InputChoice(id: $0.id, name: $0.name) }
        selectedDisplayID = displays.first?.id
        selectedCameraID = cameras.first?.id

        let program = compositor.programFrames()
        compositor.start()
        programTask = Task { [weak self] in
            var sawFrame = false
            for await frame in program {
                self?.programRelay.latest = frame.pixelBuffer
                if !sawFrame {
                    sawFrame = true
                    // A one-time milestone (not per-frame traffic): confirms the
                    // compositor is producing program frames into the preview
                    // relay at all — the background canvas ticks from the first
                    // frame even before an input delivers.
                    self?.eventBus.event("preview.firstFrame", domain: .composition)
                }
            }
        }

        await reconfigure()
    }

    /// Applies the current camera and display selection to the engine.
    ///
    /// Called from the view whenever a picker changes, and once at boot. It
    /// **coalesces**: only one pass runs at a time (the pass suspends at
    /// `input.start()`/`stop()`), and a request arriving mid-pass makes the
    /// running pass loop once more with the latest selection — so a burst of
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

    /// One reconfigure pass: starts newly chosen inputs, stops deselected
    /// ones, hands the active set to the compositor, and rebuilds the preset
    /// of shots the current inputs support.
    ///
    /// An input that cannot start (authorization denied, device gone) is
    /// reported on the bus and left out of the shots — the program keeps
    /// showing whatever else is available, never a failure state.
    private func applyConfiguration() async {
        var desired: [InputID: any Input] = [:]
        if let displayID = selectedDisplayID, let input = await registry.input(withID: displayID) {
            desired[displayID] = input
        }
        if let cameraID = selectedCameraID, let input = await registry.input(withID: cameraID) {
            desired[cameraID] = input
        }

        for (id, input) in activeInputs where desired[id] == nil {
            await input.stop()
            activeInputs[id] = nil
            eventBus.event("input.stopped", domain: .capture, params: ["id": .string(id.rawValue)])
        }
        for (id, input) in desired where activeInputs[id] == nil {
            do {
                try await input.start()
                activeInputs[id] = input
                eventBus.event(
                    "input.started",
                    domain: .capture,
                    params: ["id": .string(id.rawValue), "name": .string(input.name)]
                )
            } catch {
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

        compositor.setInputs(Array(activeInputs.values))
        eventBus.event(
            "compositor.inputs",
            domain: .composition,
            params: ["ids": .string(activeInputs.keys.map(\.rawValue).sorted().joined(separator: ","))]
        )
        rebuildPreset()
    }

    /// Takes the shot with the given id to program, using ``useDissolveTransition``
    /// to choose a cut or a dissolve (GLOSSARY.md, "Transition"). Driven by
    /// the shot switcher button; the compositor renders it starting the next
    /// tick.
    ///
    /// Reports no `tap` event itself — the switcher button's action closure
    /// in `ContentView` reports the tap before calling this, right where the
    /// user action is executed (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter shotID: The id of the shot to take to program.
    func take(_ shotID: ShotID) {
        compositor.take(shotID: shotID, transition: useDissolveTransition ? .dissolve : .cut)
        activeShotID = shotID
    }

    /// Stops the compositor, the program drain, and every active input.
    func stop() async {
        programTask?.cancel()
        programTask = nil
        compositor.stop()
        for input in activeInputs.values {
            await input.stop()
        }
        activeInputs.removeAll()
        eventBus.shutdown()
    }

    /// Rebuilds the preset of shots from the current selection (using only the
    /// inputs that actually started) and loads it into the compositor,
    /// preserving the active shot's role across the rebuild when it still
    /// exists — switching a camera keeps you on "Picture in Picture" rather
    /// than snapping back to a default. The shot set itself lives in
    /// ``ProgramLayout``, so it is unit-tested without hardware.
    private func rebuildPreset() {
        let displayID = selectedDisplayID.flatMap { activeInputs[$0] != nil ? $0 : nil }
        let cameraID = selectedCameraID.flatMap { activeInputs[$0] != nil ? $0 : nil }
        let preset = Preset(
            id: presetID,
            name: "Default",
            shots: ProgramLayout.shots(displayID: displayID, cameraID: cameraID)
        )
        compositor.loadPreset(preset)
        shots = preset.shots

        // Keep the previously active shot on program when it survives the
        // rebuild; otherwise cut to the first available shot (or none).
        let preserved = preset.shots.first { $0.id == activeShotID } ?? preset.shots.first
        if let preserved {
            compositor.take(shotID: preserved.id)
            activeShotID = preserved.id
        } else {
            activeShotID = nil
        }
    }
}

/// A plain, `@MainActor` holder for the latest program pixel buffer: the
/// writer (the ``EngineModel``'s program drain) and the reader (the
/// `MTKView` coordinator) share one instance, so the preview samples the
/// program at display rate without pushing 30 fps of state changes through
/// SwiftUI.
@MainActor
final class ProgramFrameRelay {
    /// The most recent program frame's pixel buffer, or nil before the
    /// first frame. Under the frame ownership rule the relay is the one
    /// holder; the coordinator only reads it to draw.
    var latest: CVPixelBuffer?

    /// Creates an empty relay.
    init() {}
}

/// A no-op `OutputRegistering`: the app's capture/generator plug-ins never
/// register outputs, but the shared `PlugInContext` still requires the seam.
private struct UnusedOutputRegistering: OutputRegistering {
    func register(_ provider: any StreamingServiceProvider) async throws {}
    func register(_ provider: any RecordingServiceProvider) async throws {}
}

/// A no-op `ToolRegistering`: the app does not host the MCP tool surface
/// (the daemon does), but the shared `PlugInContext` still requires the seam.
private struct UnusedToolRegistering: ToolRegistering {
    func register(_ tool: any Tool) async throws {}
}
