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

    /// The latest program frame, handed to the preview view to draw. Held
    /// in a plain relay (not observed) so the ~30 fps program does not churn
    /// SwiftUI — the `MTKView` samples it at display rate (CLOCK.md).
    @ObservationIgnored let programRelay = ProgramFrameRelay()

    /// The host event bus; the OSLog sink is the app's system of record.
    @ObservationIgnored private let eventBus = EventBus()

    /// The master clock (see CLOCK.md).
    @ObservationIgnored private let clock = HostClock()

    /// The input registry the plug-ins register into.
    @ObservationIgnored private let registry = InputRegistry()

    /// The program geometry and rate.
    @ObservationIgnored private let format = ProgramFormat(width: 1920, height: 1080, frameRate: 30)

    /// The compositor producing the program frames.
    @ObservationIgnored private lazy var compositor = Compositor(
        clock: clock,
        format: format,
        eventBus: eventBus
    )

    /// The OSLog sink's drain task, retained so the sink keeps consuming
    /// the bus for the app's lifetime.
    @ObservationIgnored private var logSinkTask: Task<Void, Never>?

    /// The inputs currently started, keyed by id, so selection changes start
    /// and stop only what actually changed.
    @ObservationIgnored private var activeInputs: [InputID: any Input] = [:]

    /// The task draining the compositor's program stream into the relay.
    @ObservationIgnored private var programTask: Task<Void, Never>?

    /// Whether ``start()`` has run, so it boots the engine once.
    @ObservationIgnored private var started = false

    /// Creates the model. The engine boots in ``start()`` when the window
    /// appears, not here.
    init() {}

    /// Boots the engine: attaches the log sink, activates the capture and
    /// generator plug-ins, discovers inputs, starts the compositor, and
    /// begins feeding the preview. Idempotent.
    func start() async {
        guard !started else { return }
        started = true

        logSinkTask = eventBus.attach(OSLogSink())
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
            for await frame in program {
                self?.programRelay.latest = frame.pixelBuffer
            }
        }

        await reconfigure()
    }

    /// Applies the current camera and display selection: starts newly chosen
    /// inputs, stops deselected ones, hands the active set to the compositor,
    /// and builds the shot (display full-frame, camera as a corner
    /// picture-in-picture over it; whichever is present alone fills the
    /// program).
    ///
    /// Called from the view whenever a picker changes. An input that cannot
    /// start (authorization denied, device gone) is reported on the bus and
    /// left out of the shot — the program keeps showing whatever else is
    /// available, never a failure state.
    func reconfigure() async {
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
        }
        for (id, input) in desired where activeInputs[id] == nil {
            do {
                try await input.start()
                activeInputs[id] = input
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
        compositor.setShot(makeShot())
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

    /// Builds the shot from the current selection, using only the inputs
    /// that actually started (a selection whose input could not start is
    /// left out). The layer arrangement itself lives in ``ProgramLayout``,
    /// so it is unit-tested without hardware.
    private func makeShot() -> Shot {
        let displayID = selectedDisplayID.flatMap { activeInputs[$0] != nil ? $0 : nil }
        let cameraID = selectedCameraID.flatMap { activeInputs[$0] != nil ? $0 : nil }
        return Shot(layers: ProgramLayout.layers(displayID: displayID, cameraID: cameraID))
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
