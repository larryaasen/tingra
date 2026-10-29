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
/// Everything the app needs from the engine passes through this one type;
/// the view layer depends only on ``Device`` values and a frame sink, never
/// on the `Input` seam or a capture framework directly (ARCHITECTURE.md,
/// "Dependency Injection Pattern"). Camera capture is the only live feed —
/// the plug-in is asked for cameras only, so the Mac's microphones are never
/// discovered.
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

    /// The camera input currently feeding the preview, or `nil` when none is
    /// showing. Retained so it can be stopped when the selection changes.
    private var currentInput: (any Input)?

    /// The task consuming the current camera's frame stream. Cancelled and
    /// replaced whenever the selected camera changes.
    private var previewTask: Task<Void, Never>?

    /// The newest frame the selected camera delivered, kept so Copy can put
    /// the picture on the pasteboard; `nil` when no camera is showing.
    /// Holding one frame pins a single buffer of the camera's pool — the
    /// latest-frame-wins rule the compositor follows — and each new frame
    /// releases the last.
    private var latestFrame: CapturedFrame?

    /// The camera switch in flight: stopping the previous camera and
    /// starting the selected one. A newer selection cancels it and waits for
    /// it to settle before starting its own camera, so only the latest
    /// choice ever reaches the preview — a slow or silent camera's start can
    /// no longer finish late and overwrite the camera the operator picked
    /// since.
    private var switchTask: Task<Void, Never>?

    /// The selected camera whose controls the panel adjusts, or nil when no
    /// camera is selected. Set as soon as a switch resolves the camera —
    /// before it starts, because a camera's controls work whether or not it
    /// is capturing.
    private var controlledInput: (any Input)?

    /// The latest parameter write in flight. Each write waits for the one
    /// before it, so the camera receives them in the order the operator
    /// made them.
    private var parameterTask: Task<Void, Never>?

    /// The long-lived task refreshing the device lists from device
    /// connect/disconnect events. Runs for the engine's lifetime.
    private var deviceEventsTask: Task<Void, Never>?

    /// One preview's frame sink: how to draw a frame in it and how to clear
    /// it.
    private struct PreviewSink {
        /// Draws one captured frame in the preview.
        let render: @MainActor (CapturedFrame) -> Void
        /// Drops any displayed frame, called when switching cameras so the
        /// previous camera's last frame does not linger.
        let flush: @MainActor () -> Void
    }

    /// Every preview on screen, keyed by its view. One per window: each
    /// window the operator opens with New Window draws the same camera, so
    /// every frame goes to all of them. A single sink, replaced by each
    /// preview that appeared, froze the earlier windows' previews — and
    /// cleared by the one that went away, froze the rest for good.
    private var previewSinks: [ObjectIdentifier: PreviewSink] = [:]

    /// The size of the frames the selected camera is delivering, or nil
    /// before its first frame. Compared on each frame so a change in size is
    /// reported once, never per frame.
    private var frameDimensions: PixelDimensions?

    /// Reports the discovered cameras whenever the set of connected devices
    /// changes, so the sidebar stays current.
    var onDevicesChanged: (@MainActor (_ cameras: [Device]) -> Void)?

    /// Reports a user-facing preview error (authorization denied, device
    /// unavailable), or `nil` once a camera is showing again.
    var onPreviewError: (@MainActor (String?) -> Void)?

    /// Reports the selected camera's adjustable controls and their current
    /// values — empty when no camera is selected or it has none (docs/UVC.md,
    /// "The Tingra Cameras controls panel").
    var onCameraParametersChanged: (@MainActor (_ parameters: [Parameter], _ values: [String: JSONValue]) -> Void)?

    /// Reports the size of the frames the selected camera delivers when it
    /// first shows and whenever it changes, or nil when no camera is showing
    /// — the status bar's resolution reading.
    var onFrameDimensionsChanged: (@MainActor (PixelDimensions?) -> Void)?

    /// Adds a preview to the set every frame is drawn in, showing it the
    /// newest frame straight away so a window opened mid-stream is not blank
    /// until the next one arrives.
    ///
    /// - Parameters:
    ///   - id: The preview's identity, used to remove it again.
    ///   - render: Draws one captured frame in the preview.
    ///   - flush: Clears any displayed frame.
    func addPreviewSink(
        id: ObjectIdentifier,
        render: @escaping @MainActor (CapturedFrame) -> Void,
        flush: @escaping @MainActor () -> Void
    ) {
        previewSinks[id] = PreviewSink(render: render, flush: flush)
        if let latestFrame {
            render(latestFrame)
        }
    }

    /// Removes a preview from the set, when its view goes away, leaving every
    /// other preview drawing.
    ///
    /// - Parameter id: The identity the preview was added under.
    func removePreviewSink(id: ObjectIdentifier) {
        previewSinks[id] = nil
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

    /// Shows the camera with the given identifier in the preview, stopping
    /// whichever camera was showing before.
    ///
    /// Passing `nil` (or an identifier no longer registered) stops the
    /// preview. Authorization denial and device unavailability surface
    /// through ``onPreviewError`` rather than crashing (CLAUDE.md,
    /// never-crash rule).
    ///
    /// The latest call wins: a camera still starting when another is chosen
    /// — a built-in camera behind a closed lid waits out the input's whole
    /// verification window before it reports itself silent — is cancelled,
    /// and its outcome never reaches the preview.
    ///
    /// - Parameters:
    ///   - id: The selected camera's identifier, or `nil` to stop.
    ///   - values: Control values to write to the camera before its controls
    ///     are read and shown — a recalled camera preset's — or nil to leave
    ///     the camera's own values.
    func showCamera(id: Device.ID?, applying values: [String: JSONValue]? = nil) async {
        let previousSwitch = switchTask
        previousSwitch?.cancel()
        let currentSwitch = Task { [weak self] in
            // Let the superseded switch release its camera first, so two
            // capture sessions are never starting at once.
            await previousSwitch?.value
            guard !Task.isCancelled else { return }
            await self?.switchCamera(to: id, applying: values)
        }
        switchTask = currentSwitch
        await currentSwitch.value
    }

    /// Stops the camera showing now and starts the given one, the body of a
    /// single switch. Runs inside ``switchTask``, whose cancellation means a
    /// newer selection has superseded this one.
    ///
    /// - Parameters:
    ///   - id: The camera to show, or `nil` to stop the preview.
    ///   - values: Control values to write before the controls are read, or
    ///     nil.
    private func switchCamera(to id: Device.ID?, applying values: [String: JSONValue]?) async {
        // Tear down the previous feed first: cancel its consumer and stop
        // the device so only one camera is ever open at a time.
        previewTask?.cancel()
        previewTask = nil
        if let previous = currentInput {
            await previous.stop()
            currentInput = nil
            eventBus.event(
                "input.stopped",
                domain: .capture,
                params: ["id": .string(previous.id.rawValue), "name": .string(previous.name)]
            )
        }
        for sink in previewSinks.values {
            sink.flush()
        }
        latestFrame = nil
        frameDimensions = nil
        onFrameDimensionsChanged?(nil)
        controlledInput = nil
        onCameraParametersChanged?([], [:])

        guard let id, let input = await inputs.input(withID: InputID(rawValue: id)) else { return }

        // A preset's values go in before the controls are read, so the panel
        // shows what the camera holds once they are written — the camera
        // takes them whether or not it is capturing.
        if let values {
            await input.setParameters(values)
            guard !Task.isCancelled else { return }
        }

        // Show the camera's controls while it starts: they adjust the camera
        // whether or not it is capturing, and a slow start should not hide
        // them.
        await showControls(of: input)
        guard !Task.isCancelled else { return }

        do {
            try await input.start()
        } catch is CancellationError {
            // A newer selection superseded this one; the start tore its
            // session down, and the newer switch reports its own outcome.
            return
        } catch {
            // Report the failure on the bus (CLAUDE.md: report errors as
            // `error` events; code never logs directly) in addition to the
            // UI-facing closure, so a denied/unavailable camera is visible
            // in the console, not just silently reflected in the preview.
            eventBus.error(
                "input.start",
                domain: .capture,
                params: [
                    "id": .string(input.id.rawValue),
                    "name": .string(input.name),
                    "error": .string(Self.message(for: error)),
                ]
            )
            // A superseded start's error is still logged above, but the
            // preview belongs to the newer selection.
            guard !Task.isCancelled else { return }
            onPreviewError?(Self.message(for: error))
            return
        }
        guard !Task.isCancelled else {
            // The first frame landed just as a newer selection superseded
            // this one: release the camera rather than show it.
            await input.stop()
            return
        }
        currentInput = input
        onPreviewError?(nil)
        eventBus.event(
            "input.started",
            domain: .capture,
            params: ["id": .string(input.id.rawValue), "name": .string(input.name)]
        )

        // Pull frames on the main actor and hand each straight to the
        // preview sink, transferring ownership at the yield (the frame
        // ownership rule) — no per-frame SwiftUI invalidation is involved.
        previewTask = Task { [weak self] in
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
                self?.present(frame)
            }
        }
    }

    /// Draws a frame in every preview, keeps it for Copy, and reports its
    /// size when that differs from the last frame's.
    ///
    /// - Parameter frame: The newest frame from the selected camera.
    private func present(_ frame: CapturedFrame) {
        latestFrame = frame
        let dimensions = PixelDimensions(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        if dimensions != frameDimensions {
            frameDimensions = dimensions
            onFrameDimensionsChanged?(dimensions)
        }
        for sink in previewSinks.values {
            sink.render(frame)
        }
    }

    /// Reads a camera's controls and current values and reports them, unless
    /// a newer selection has superseded this switch meanwhile.
    ///
    /// - Parameter input: The selected camera.
    private func showControls(of input: any Input) async {
        let values = await input.currentParameters()
        guard !Task.isCancelled else { return }
        controlledInput = input
        onCameraParametersChanged?(input.parameters, values)
    }

    /// Writes the selected camera's control values — the panel's whole
    /// payload, of which the camera writes only what changed — after any
    /// write still in flight.
    ///
    /// - Parameters:
    ///   - values: Every control's value, keyed by parameter.
    ///   - refreshing: Whether to read the camera's values back afterwards
    ///     and report them: true after an Auto switch flips, because the
    ///     values it governs are the camera's again (an exposure time chosen
    ///     under Auto Exposure becomes the manual starting point). A response
    ///     to the operator's action, never a poll.
    func setCameraParameters(_ values: [String: JSONValue], refreshing: Bool) {
        guard let input = controlledInput else { return }
        let previous = parameterTask
        parameterTask = Task { [weak self] in
            await previous?.value
            await input.setParameters(values)
            guard refreshing else { return }
            let fresh = await input.currentParameters()
            guard let self, self.controlledInput?.id == input.id else { return }
            self.onCameraParametersChanged?(input.parameters, fresh)
        }
    }

    /// Writes control values to a camera that is already selected — a
    /// recalled camera preset's — once any switch in flight has settled,
    /// then reads the camera's values back and reports them. Dropped when a
    /// different camera has been selected meanwhile, so one camera's preset
    /// never reaches another.
    ///
    /// - Parameters:
    ///   - values: The control values, keyed by parameter.
    ///   - id: The camera they are for.
    func applyCameraParameters(_ values: [String: JSONValue], toCamera id: Device.ID) async {
        await switchTask?.value
        guard controlledInput?.id.rawValue == id else { return }
        setCameraParameters(values, refreshing: true)
        await parameterTask?.value
    }

    /// Puts the selected camera's newest frame on the general pasteboard as
    /// an image, at the camera's full resolution and without the preview's
    /// cross bars, reporting a `preview.copied` event — or a `preview.copy`
    /// error when there is no frame to copy or it cannot be converted.
    func copyCurrentFrame() {
        guard let frame = latestFrame, let input = currentInput else {
            eventBus.error(
                "preview.copy",
                domain: .capture,
                params: ["error": .string("No camera frame to copy: no camera is showing yet.")]
            )
            return
        }
        guard let image = FrameClipboard.image(from: frame.pixelBuffer) else {
            eventBus.error(
                "preview.copy",
                domain: .capture,
                params: [
                    "id": .string(input.id.rawValue),
                    "error": .string("The camera frame could not be converted to an image."),
                ]
            )
            return
        }
        FrameClipboard.copy(image)
        eventBus.event(
            "preview.copied",
            domain: .capture,
            params: [
                "id": .string(input.id.rawValue),
                "width": .int(image.width),
                "height": .int(image.height),
            ]
        )
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

    /// Stops the preview and releases the camera, e.g. when the window
    /// closes. Safe to call more than once.
    func stop() async {
        // Settle any switch in flight first, so a camera still starting
        // cannot come up after the preview has stopped.
        switchTask?.cancel()
        await switchTask?.value
        switchTask = nil
        previewTask?.cancel()
        previewTask = nil
        if let current = currentInput {
            await current.stop()
            currentInput = nil
            eventBus.event(
                "input.stopped",
                domain: .capture,
                params: ["id": .string(current.id.rawValue), "name": .string(current.name)]
            )
        }
        latestFrame = nil
        frameDimensions = nil
        onFrameDimensionsChanged?(nil)
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
    private static func message(for error: any Error) -> String {
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
