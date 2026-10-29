//
//  AVFoundationCapturePlugIn.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import TingraEventBus
import TingraPlugInKit

/// The AVFoundation-backed capture plug-in: contributes the Mac's cameras
/// and microphones as inputs with stable identifiers, and reports device
/// connection and disconnection on the event bus. A front end that needs
/// only one kind (Tingra Cameras, which shows no microphone) asks for just
/// that kind, and the other is never discovered.
///
/// AVFoundation is imported only here, behind the `Input` seam — nothing
/// downstream of the registry knows which framework produced these inputs
/// (see ARCHITECTURE.md, "Dependency Injection Pattern").
public struct AVFoundationCapturePlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.capture.avfoundation")

    /// The plug-in's user-facing name.
    public let name = "AVFoundation Capture"

    /// The kinds of device the plug-in contributes — cameras, microphones,
    /// or both. A device of another kind is neither discovered nor
    /// registered when it connects, and reports no event.
    public let deviceKinds: Set<InputKind>

    /// Enumerates the connected capture devices. Production reads
    /// AVFoundation's discovery sessions; tests inject fixtures so no
    /// camera, microphone, or TCC authorization is needed on runners.
    private let enumerateDevices: @Sendable () -> [CaptureDevice]

    /// The device connection/disconnection stream. Production observes
    /// AVFoundation's notifications; tests inject a scripted stream.
    private let deviceChanges: @Sendable () -> AsyncStream<DeviceChange>

    /// Describes a camera's adjustable controls, or returns nil for a camera
    /// with none. Production reads the UVC camera behind the device
    /// (``UVCCameraControls``); tests inject fixtures, or nothing, so no
    /// USB device is touched on runners.
    private let describeCameraControls: @Sendable (CaptureDevice) throws -> (any CameraControls)?

    /// Creates the production plug-in, enumerating real AVFoundation
    /// devices and observing real device notifications.
    ///
    /// - Parameter deviceKinds: The kinds of device to contribute; cameras
    ///   and microphones unless the front end asks for fewer. Only
    ///   ``InputKind/camera`` and ``InputKind/microphone`` mean anything
    ///   here.
    public init(deviceKinds: Set<InputKind> = [.camera, .microphone]) {
        self.init(
            deviceKinds: deviceKinds,
            enumerateDevices: { Self.connectedDevices(of: deviceKinds) },
            deviceChanges: DeviceEventReporter.liveChanges,
            describeCameraControls: UVCCameraControls.describe
        )
    }

    /// Creates a plug-in over an injected device enumerator, change stream,
    /// and camera control description (the test seams). Cameras get no
    /// controls unless a test describes some.
    init(
        deviceKinds: Set<InputKind> = [.camera, .microphone],
        enumerateDevices: @escaping @Sendable () -> [CaptureDevice],
        deviceChanges: @escaping @Sendable () -> AsyncStream<DeviceChange> = DeviceEventReporter.liveChanges,
        describeCameraControls: @escaping @Sendable (CaptureDevice) throws -> (any CameraControls)? = { _ in nil }
    ) {
        self.deviceKinds = deviceKinds
        self.enumerateDevices = enumerateDevices
        self.deviceChanges = deviceChanges
        self.describeCameraControls = describeCameraControls
    }

    /// Registers one input per connected device of ``deviceKinds``, reporting
    /// each discovery as a `trace` event, then keeps the registry current
    /// from device notifications, reporting each change as a
    /// `device.connected` / `device.disconnected` event — normal events,
    /// never errors, never polling (`stream` sessions and
    /// `devices --watch` both consume them).
    ///
    /// macOS's private aggregate devices are declined here, with an
    /// `input.ignored` trace, rather than in the enumerator: AVFoundation
    /// reports them as microphones, and the test that tells them apart is
    /// the plug-in's rule, not the framework's (``PrivateAggregateDevice``).
    ///
    /// Throws if the registry rejects an input (a duplicate identifier);
    /// the host's loader reports that as an `error` event and the engine
    /// keeps running.
    public func activate(in context: PlugInContext) async throws {
        for device in enumerateDevices() where deviceKinds.contains(device.kind) {
            guard !PrivateAggregateDevice.isPrivate(uid: device.uniqueID) else {
                PrivateAggregateDevice.reportIgnored(device, on: context.eventBus)
                continue
            }
            try await context.inputs.register(
                Self.makeInput(for: device, eventBus: context.eventBus, describeControls: describeCameraControls))
            context.eventBus.trace(
                "input.discovered",
                domain: .capture,
                params: [
                    "id": .string(device.uniqueID),
                    "name": .string(device.name),
                    "kind": .string(device.kind.rawValue),
                ]
            )
        }

        // Fire and forget for the life of the process: the reporter ends
        // when its notification stream does. There is no deactivation hook
        // yet — plug-ins live as long as the engine.
        let eventBus = context.eventBus
        let describeCameraControls = self.describeCameraControls
        let reporter = DeviceEventReporter(
            changes: deviceChanges(),
            deviceKinds: deviceKinds,
            makeInput: { Self.makeInput(for: $0, eventBus: eventBus, describeControls: describeCameraControls) }
        )
        let inputs = context.inputs
        Task {
            await reporter.run(on: eventBus, inputs: inputs)
        }
    }

    /// The plug-in's input factory: a camera or microphone input over a
    /// discovered device, used at activation and for later connections.
    ///
    /// - Parameters:
    ///   - device: The discovered device to build an input for.
    ///   - eventBus: The host's event bus, handed to the input so it can
    ///     report its own capture diagnostics (the negotiated audio format,
    ///     a retried bring-up, a camera session that dies after starting)
    ///     rather than leaving them to AVFoundation's console logging, which
    ///     never reaches a sink.
    ///   - describeControls: Describes a camera's adjustable controls.
    /// - Returns: The input.
    private static func makeInput(
        for device: CaptureDevice,
        eventBus: EventBus,
        describeControls: @Sendable (CaptureDevice) throws -> (any CameraControls)?
    ) -> any Input {
        guard device.kind == .camera else {
            return MicrophoneInput(device: device, eventBus: eventBus)
        }
        return CameraInput(
            device: device,
            eventBus: eventBus,
            controls: cameraControls(for: device, eventBus: eventBus, describe: describeControls)
        )
    }

    /// Describes a camera's adjustable controls — a handful of USB control
    /// transfers, once per discovery or connection — reporting the outcome
    /// on the bus: an `input.controls` trace naming how many parameters the
    /// camera declares, or an `input.controls` error when a UVC camera
    /// cannot be described. The camera is registered either way; it just has
    /// no controls then.
    ///
    /// - Parameters:
    ///   - device: The discovered camera.
    ///   - eventBus: The host's event bus.
    ///   - describe: The description seam.
    /// - Returns: The controls, or nil.
    private static func cameraControls(
        for device: CaptureDevice,
        eventBus: EventBus,
        describe: @Sendable (CaptureDevice) throws -> (any CameraControls)?
    ) -> (any CameraControls)? {
        do {
            guard let controls = try describe(device) else { return nil }
            eventBus.trace(
                "input.controls",
                domain: .capture,
                params: [
                    "id": .string(device.uniqueID),
                    "name": .string(device.name),
                    "parameters": .int(controls.parameters.count),
                ]
            )
            return controls
        } catch {
            eventBus.error(
                "input.controls",
                domain: .capture,
                params: [
                    "id": .string(device.uniqueID),
                    "name": .string(device.name),
                    "error": .string(String(describing: error)),
                ]
            )
            return nil
        }
    }

    /// Reads the connected cameras and microphones from AVFoundation —
    /// querying only the kinds asked for, so a front end without
    /// microphones never enumerates audio devices.
    ///
    /// Discovery does not capture, so it needs no TCC authorization. It
    /// reports current state at the moment of the call — device connection
    /// and disconnection afterwards is a normal event, not an error.
    ///
    /// - Parameter kinds: The kinds of device to read.
    /// - Returns: The connected devices of those kinds, cameras first.
    private static func connectedDevices(of kinds: Set<InputKind>) -> [CaptureDevice] {
        let cameras =
            kinds.contains(.camera)
            ? AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
                mediaType: .video,
                position: .unspecified
            ).devices : []
        let microphones =
            kinds.contains(.microphone)
            ? AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices : []
        return cameras.map { CaptureDevice(uniqueID: $0.uniqueID, name: $0.localizedName, kind: .camera) }
            + microphones.map { CaptureDevice(uniqueID: $0.uniqueID, name: $0.localizedName, kind: .microphone) }
    }
}
