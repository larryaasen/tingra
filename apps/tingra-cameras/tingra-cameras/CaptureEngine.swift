//
//  CaptureEngine.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreVideo
import TingraCapturePlugIns
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// The app's bridge to the Tingra engine: it stands up a minimal host
/// (event bus, registries, master clock, plug-in loader), activates the
/// first-party AVFoundation capture plug-in to discover the Mac's cameras,
/// and drives the selected camera's `Input` so its frames reach the
/// preview.
///
/// Everything the app needs from the engine passes through this one type
/// and the per-window ``CameraFeed``s it makes; the view layer depends only
/// on ``Device`` values and a frame sink, never on the `Input` seam or a
/// capture framework directly (ARCHITECTURE.md, "Dependency Injection
/// Pattern"). Camera capture is the only live feed — the plug-in is asked
/// for cameras only, so the Mac's microphones are never discovered.
///
/// **Each window shows its own camera.** A window's ``CameraFeed`` chooses
/// the camera; the engine runs it. A camera input has one frame consumer at
/// a time, so two windows showing the same camera share one running camera
/// (``RunningCamera``): the engine starts it for the first window that
/// subscribes, draws each frame in every subscribed window, and stops it
/// when the last one leaves.
@MainActor
final class CaptureEngine {
    /// The host's event bus. The capture plug-in reports device discovery
    /// and connect/disconnect here; the engine subscribes to keep the
    /// device lists current without polling. Internal rather than private so
    /// the permissions model reports its `authorization.*` events on the
    /// same bus (``PermissionsModel``).
    let eventBus = EventBus()

    /// The master clock the plug-in stamps frames against (see CLOCK.md).
    private let clock = HostClock()

    /// The input registry the capture plug-in registers the cameras into,
    /// and the engine resolves the selected camera from.
    private let inputs = InputRegistry()

    /// The output registration seam, unused here but required to build the
    /// plug-in context; this app streams nothing.
    private let outputs = OutputRegistry()

    /// The effect registration seam, unused here but required to build the
    /// plug-in context; this app hosts no effect chains.
    private let effects = EffectRegistry()

    /// The tool registration seam, unused here but required to build the
    /// plug-in context; this app hosts no MCP tools.
    private let tools = ToolRegistry()

    /// The plug-in lifecycle used to activate the capture plug-in.
    private let loader = PlugInLoader()

    /// Formats bus events into the project's human log line for the console.
    private let logFormatter = LogLineFormatter()

    /// The task printing every bus event to standard output, so engine
    /// activity is visible in the Xcode console. Runs for the engine's
    /// lifetime. (OSLog does not surface in Xcode's console, so the app
    /// prints the events itself — the same approach as the main Tingra app.)
    private var consoleTask: Task<Void, Never>?

    /// The long-lived task refreshing the device lists from device
    /// connect/disconnect events. Runs for the engine's lifetime.
    private var deviceEventsTask: Task<Void, Never>?

    /// The cameras some window is showing or starting, by camera
    /// identifier: one running camera however many windows show it.
    private var runningCameras: [Device.ID: RunningCamera] = [:]

    /// The stops in flight, by camera identifier. A camera chosen again
    /// while its last window's stop is still releasing it waits for the stop
    /// before starting, so one input never starts while it is stopping.
    private var stoppingCameras: [Device.ID: Task<Void, Never>] = [:]

    /// Reports the discovered cameras whenever the set of connected devices
    /// changes, so the sidebar stays current.
    var onDevicesChanged: (@MainActor (_ cameras: [Device]) -> Void)?

    /// Makes the feed a window shows its camera through. Each window has
    /// its own, so each can show a different camera.
    ///
    /// - Returns: A feed showing no camera yet.
    func makeFeed() -> CameraFeed {
        CameraFeed(engine: self)
    }

    /// Activates the capture plug-in, starts observing device changes, and
    /// returns the cameras discovered right now.
    ///
    /// - Returns: The discovered cameras, sorted by name for stable
    ///   presentation.
    func discover() async -> [Device] {
        // Start printing events before activating anything, so the plug-in's
        // discovery and activation events show up in the console.
        startConsoleLogging()

        let context = PlugInContext(
            eventBus: eventBus,
            clock: clock,
            inputs: inputs,
            outputs: outputs,
            effects: effects,
            tools: tools
        )
        await loader.activate([AVFoundationCapturePlugIn(deviceKinds: [.camera])], in: context)
        startObservingDeviceChanges()
        return await currentCameras()
    }

    /// The registered camera input with an identifier, or nil when no camera
    /// with it is connected.
    ///
    /// - Parameter id: The camera's identifier.
    /// - Returns: The input, or nil.
    func cameraInput(withID id: Device.ID) async -> (any Input)? {
        await inputs.input(withID: InputID(rawValue: id))
    }

    /// Subscribes a feed to a camera: starts the camera if no window is
    /// showing it yet, and returns once it is delivering frames, which then
    /// reach the subscriber's handler. A camera another window already shows
    /// returns at once, after handing over its newest frame so the new window
    /// is not blank until the next one.
    ///
    /// Cancelling the calling task returns at once with `CancellationError`,
    /// leaving the subscriber registered: the feed unsubscribes as it tears
    /// down, and the camera's start is cancelled only if no other window
    /// still waits for it.
    ///
    /// - Parameters:
    ///   - subscriber: The feed's frame and control-value handlers.
    ///   - input: The camera to show.
    /// - Throws: The camera's start error — authorization denied, device
    ///   unavailable — or `CancellationError`.
    func subscribe(_ subscriber: CameraSubscriber, to input: any Input) async throws {
        try Task.checkCancellation()
        let id = input.id.rawValue
        let camera: RunningCamera
        if let running = runningCameras[id] {
            camera = running
        } else {
            camera = RunningCamera(input: input)
            runningCameras[id] = camera
            let pendingStop = stoppingCameras[id]
            camera.startTask = Task { [weak self] in
                await pendingStop?.value
                await self?.start(camera)
            }
        }
        camera.subscribers[subscriber.id] = subscriber
        guard camera.isStarting else {
            if let latestFrame = camera.latestFrame {
                subscriber.onFrame(latestFrame)
            }
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                camera.waiters[subscriber.id] = continuation
            }
        } onCancel: {
            // Runs after the continuation is stored: the body above runs
            // synchronously on the main actor, and this hops back onto it.
            Task { @MainActor in
                camera.waiters.removeValue(forKey: subscriber.id)?.resume(throwing: CancellationError())
            }
        }
    }

    /// Removes a feed from a camera, stopping the camera when no window shows
    /// it any longer. Safe to call for a camera the feed never subscribed
    /// to, or one whose start failed.
    ///
    /// - Parameters:
    ///   - subscriberID: The feed's identity.
    ///   - cameraID: The camera it was showing.
    func unsubscribe(_ subscriberID: ObjectIdentifier, from cameraID: Device.ID) async {
        guard let camera = runningCameras[cameraID] else { return }
        camera.subscribers[subscriberID] = nil
        camera.waiters.removeValue(forKey: subscriberID)?.resume(throwing: CancellationError())
        guard camera.subscribers.isEmpty else { return }
        runningCameras[cameraID] = nil
        let stop = Task { [weak self] in
            camera.startTask?.cancel()
            camera.frameTask?.cancel()
            // Let a start in flight settle — cancelled, it tears its own
            // session down — before releasing a camera that came up.
            await camera.startTask?.value
            guard camera.isRunning else { return }
            await camera.input.stop()
            self?.eventBus.event(
                "input.stopped",
                domain: .capture,
                params: ["id": .string(camera.input.id.rawValue), "name": .string(camera.input.name)]
            )
        }
        stoppingCameras[cameraID] = stop
        await stop.value
        if stoppingCameras[cameraID] == stop {
            stoppingCameras[cameraID] = nil
        }
    }

    /// Tells every other window showing a camera that its control values
    /// changed, so each window's controls show what the camera holds.
    ///
    /// - Parameters:
    ///   - values: The camera's control values now.
    ///   - cameraID: The camera.
    ///   - subscriberID: The feed that changed them, which already shows
    ///     them.
    func cameraParametersChanged(
        _ values: [String: JSONValue],
        of cameraID: Device.ID,
        by subscriberID: ObjectIdentifier
    ) {
        guard let camera = runningCameras[cameraID] else { return }
        for (id, subscriber) in camera.subscribers where id != subscriberID {
            subscriber.onParameters(values)
        }
    }

    /// Starts a running camera's input and, once it delivers, its frame
    /// fan-out — the body of the camera's start task. Every window waiting
    /// for the camera is told how the start went.
    ///
    /// - Parameter camera: The camera to start.
    private func start(_ camera: RunningCamera) async {
        let input = camera.input
        do {
            try await input.start()
        } catch {
            camera.state = .stopped
            if runningCameras[input.id.rawValue] === camera {
                runningCameras[input.id.rawValue] = nil
            }
            if !(error is CancellationError) {
                // Report the failure on the bus (CLAUDE.md: report errors as
                // `error` events; code never logs directly) in addition to
                // the windows' previews, so a denied/unavailable camera is
                // visible in the console, not just silently reflected.
                eventBus.error(
                    "input.start",
                    domain: .capture,
                    params: [
                        "id": .string(input.id.rawValue),
                        "name": .string(input.name),
                        "error": .string(Self.message(for: error)),
                    ]
                )
            }
            camera.resumeWaiters(throwing: error)
            return
        }
        guard !Task.isCancelled else {
            // The first frame landed just as the last window left: release
            // the camera rather than show it.
            camera.state = .stopped
            await input.stop()
            camera.resumeWaiters(throwing: CancellationError())
            return
        }
        camera.state = .running
        eventBus.event(
            "input.started",
            domain: .capture,
            params: ["id": .string(input.id.rawValue), "name": .string(input.name)]
        )

        // Pull frames on the main actor and hand each straight to every
        // window's handler, transferring ownership at the yield (the frame
        // ownership rule) — no per-frame SwiftUI invalidation is involved.
        camera.frameTask = Task { [weak self, weak camera] in
            var receivedFirstFrame = false
            for await frame in input.frames() {
                if Task.isCancelled { break }
                if !receivedFirstFrame {
                    receivedFirstFrame = true
                    self?.eventBus.event(
                        "preview.firstFrame",
                        domain: .capture,
                        params: ["id": .string(input.id.rawValue), "name": .string(input.name)]
                    )
                }
                camera?.present(frame)
            }
        }
        camera.resumeWaiters(throwing: nil)
    }

    /// Records a UI tap on the event bus with its own parameters, for a
    /// control whose tap carries more than a device — a camera control's
    /// key and value, or a setting's new value.
    ///
    /// - Parameters:
    ///   - name: The dotted tap name, e.g. `cameraParameter.slider`.
    ///   - domain: The emitting area: `capture` for the camera's own
    ///     controls (the default), `platform` for the app's settings.
    ///   - params: The tap's parameters, or nil for none.
    func recordTap(_ name: String, domain: EventDomain = .capture, params: [String: EventValue]?) {
        eventBus.tap(name, domain: domain, params: params)
    }

    /// Records a UI tap on the event bus, distinct from the action it
    /// triggers (see EVENTS.md, "The `tap` convention"). Called first from a
    /// control's handler so the click is logged even when it changes nothing.
    ///
    /// - Parameters:
    ///   - name: The dotted tap name, e.g. `cameraSelect.row`.
    ///   - deviceID: The device the tap concerns, included as a param when
    ///     present.
    func recordTap(_ name: String, deviceID: Device.ID? = nil) {
        var params: [String: EventValue]?
        if let deviceID {
            params = ["id": .string(deviceID)]
        }
        eventBus.tap(name, domain: .capture, params: params)
    }

    /// Stops every camera any window shows and the engine's own tasks, e.g.
    /// as the app quits. Safe to call more than once.
    func stop() async {
        for (cameraID, camera) in runningCameras {
            for subscriberID in Array(camera.subscribers.keys) {
                await unsubscribe(subscriberID, from: cameraID)
            }
        }
        deviceEventsTask?.cancel()
        deviceEventsTask = nil
        consoleTask?.cancel()
        consoleTask = nil
    }

    /// Subscribes a console sink to the event bus, printing every event as a
    /// formatted log line to standard output so engine activity is visible in
    /// the Xcode console.
    ///
    /// The stream is created synchronously here so the subscription exists
    /// before any events are emitted; the print loop then runs on its own
    /// task. Every `events()` call is an independent subscription, so this
    /// does not interfere with the device-change observer.
    private func startConsoleLogging() {
        guard consoleTask == nil else { return }
        let events = eventBus.events()
        consoleTask = Task { [logFormatter] in
            for await event in events {
                if Task.isCancelled { break }
                print(logFormatter.line(for: event))
            }
        }
    }

    /// Rebuilds the device lists from the registry whenever a device
    /// connects or disconnects — a normal event, never an error, and never a
    /// poll loop (CLAUDE.md; the capture plug-in keeps the registry current).
    private func startObservingDeviceChanges() {
        guard deviceEventsTask == nil else { return }
        deviceEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventBus.events() {
                if Task.isCancelled { break }
                guard event.domain == .capture,
                    event.name == "device.connected" || event.name == "device.disconnected"
                else { continue }
                onDevicesChanged?(await currentCameras())
            }
        }
    }

    /// Reads the registered camera inputs and maps them to view-facing
    /// ``Device`` values, sorted by name. The capture plug-in is asked for
    /// cameras only; the kind filter keeps the list to cameras whatever else
    /// a later plug-in registers.
    private func currentCameras() async -> [Device] {
        await inputs.allInputs
            .filter { $0.kind == .camera }
            .map(Device.init(input:))
            .sorted { $0.name < $1.name }
    }

    /// Turns an engine error into a short, user-facing preview message.
    static func message(for error: any Error) -> String {
        if let captureError = error as? CaptureInputError {
            return captureError.description
        }
        return String(describing: error)
    }
}

/// The size of a camera's frames, in pixels — the status bar's resolution
/// reading.
struct PixelDimensions: Equatable, Sendable {
    /// The frame's width, in pixels.
    let width: Int
    /// The frame's height, in pixels.
    let height: Int
}

extension Device {
    /// Creates a view-facing device from an engine input.
    ///
    /// - Parameter input: The registered camera input to represent.
    fileprivate init(input: any Input) {
        self.init(id: input.id.rawValue, name: input.name)
    }
}
