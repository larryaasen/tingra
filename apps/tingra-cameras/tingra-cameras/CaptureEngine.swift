//
//  CaptureEngine.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraCapturePlugIns
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// The app's bridge to the Tingra engine: it stands up a minimal host
/// (event bus, registries, master clock, plug-in loader), activates the
/// first-party AVFoundation capture plug-in to discover the Mac's cameras
/// and microphones, and drives the selected camera's `Input` so its frames
/// reach the preview.
///
/// Everything the app needs from the engine passes through this one type;
/// the view layer depends only on ``Device`` values and a frame sink, never
/// on the `Input` seam or a capture framework directly (ARCHITECTURE.md,
/// "Dependency Injection Pattern"). Camera capture is the only live feed —
/// microphones are discovered for the sidebar but not opened.
@MainActor
final class CaptureEngine {
    /// The host's event bus. The capture plug-in reports device discovery
    /// and connect/disconnect here; the engine subscribes to keep the
    /// device lists current without polling.
    private let eventBus = EventBus()

    /// The master clock the plug-in stamps frames against (see CLOCK.md).
    private let clock = HostClock()

    /// The input registry the capture plug-in registers cameras and
    /// microphones into, and the engine resolves the selected camera from.
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

    /// The long-lived task refreshing the device lists from device
    /// connect/disconnect events. Runs for the engine's lifetime.
    private var deviceEventsTask: Task<Void, Never>?

    /// Delivers each captured frame to the preview, set by the preview view.
    /// Cleared when the preview view goes away so frames stop being drawn.
    var renderFrame: (@MainActor (CapturedFrame) -> Void)?

    /// Asks the preview to drop any displayed frame, called when switching
    /// cameras so the previous camera's last frame does not linger.
    var flushPreview: (@MainActor () -> Void)?

    /// Reports the discovered cameras and microphones whenever the set of
    /// connected devices changes, so the sidebar stays current.
    var onDevicesChanged: (@MainActor (_ cameras: [Device], _ microphones: [Device]) -> Void)?

    /// Reports a user-facing preview error (authorization denied, device
    /// unavailable), or `nil` once a camera is showing again.
    var onPreviewError: (@MainActor (String?) -> Void)?

    /// Activates the capture plug-in, starts observing device changes, and
    /// returns the cameras and microphones discovered right now.
    ///
    /// - Returns: The discovered cameras and microphones, split by kind and
    ///   sorted by name for stable presentation.
    func discover() async -> (cameras: [Device], microphones: [Device]) {
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
        await loader.activate([AVFoundationCapturePlugIn()], in: context)
        startObservingDeviceChanges()
        return await currentDevices()
    }

    /// Shows the camera with the given identifier in the preview, stopping
    /// whichever camera was showing before.
    ///
    /// Passing `nil` (or an identifier no longer registered) stops the
    /// preview. Authorization denial and device unavailability surface
    /// through ``onPreviewError`` rather than crashing (CLAUDE.md,
    /// never-crash rule).
    ///
    /// - Parameter id: The selected camera's identifier, or `nil` to stop.
    func showCamera(id: Device.ID?) async {
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
        flushPreview?()

        guard let id, let input = await inputs.input(withID: InputID(rawValue: id)) else { return }

        do {
            try await input.start()
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
            onPreviewError?(Self.message(for: error))
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
                self?.renderFrame?(frame)
            }
        }
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
                let devices = await currentDevices()
                onDevicesChanged?(devices.cameras, devices.microphones)
            }
        }
    }

    /// Reads the registered inputs and maps them to view-facing ``Device``
    /// values, split by kind and sorted by name.
    private func currentDevices() async -> (cameras: [Device], microphones: [Device]) {
        let all = await inputs.allInputs.map(Device.init(input:))
        let cameras = all.filter { $0.kind == .camera }.sorted { $0.name < $1.name }
        let microphones = all.filter { $0.kind == .microphone }.sorted { $0.name < $1.name }
        return (cameras, microphones)
    }

    /// Turns an engine error into a short, user-facing preview message.
    private static func message(for error: any Error) -> String {
        if let captureError = error as? CaptureInputError {
            return captureError.description
        }
        return String(describing: error)
    }
}

extension Device {
    /// Creates a view-facing device from an engine input, mapping the input
    /// kind onto the sidebar's camera/microphone distinction.
    ///
    /// - Parameter input: The registered engine input to represent.
    fileprivate init(input: any Input) {
        self.init(
            id: input.id.rawValue,
            name: input.name,
            kind: input.kind == .camera ? .camera : .microphone
        )
    }
}
