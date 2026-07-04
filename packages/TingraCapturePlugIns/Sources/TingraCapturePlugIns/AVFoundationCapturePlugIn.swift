//
//  AVFoundationCapturePlugIn.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import TingraPlugInKit

/// The AVFoundation-backed capture plug-in: contributes the Mac's cameras
/// and microphones as inputs with stable identifiers, and reports device
/// connection and disconnection on the event bus.
///
/// AVFoundation is imported only here, behind the `Input` seam — nothing
/// downstream of the registry knows which framework produced these inputs
/// (see ARCHITECTURE.md, "Dependency Injection Pattern").
public struct AVFoundationCapturePlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.capture.avfoundation")

    /// The plug-in's user-facing name.
    public let name = "AVFoundation Capture"

    /// Enumerates the connected capture devices. Production reads
    /// AVFoundation's discovery sessions; tests inject fixtures so no
    /// camera, microphone, or TCC authorization is needed on runners.
    private let enumerateDevices: @Sendable () -> [CaptureDevice]

    /// The device connection/disconnection stream. Production observes
    /// AVFoundation's notifications; tests inject a scripted stream.
    private let deviceChanges: @Sendable () -> AsyncStream<DeviceChange>

    /// Creates the production plug-in, enumerating real AVFoundation
    /// devices and observing real device notifications.
    public init() {
        self.init(enumerateDevices: Self.connectedDevices, deviceChanges: DeviceEventReporter.liveChanges)
    }

    /// Creates a plug-in over an injected device enumerator and change
    /// stream (the test seams).
    init(
        enumerateDevices: @escaping @Sendable () -> [CaptureDevice],
        deviceChanges: @escaping @Sendable () -> AsyncStream<DeviceChange> = DeviceEventReporter.liveChanges
    ) {
        self.enumerateDevices = enumerateDevices
        self.deviceChanges = deviceChanges
    }

    /// Registers one input per connected camera and microphone, reporting
    /// each discovery as a `trace` event, then keeps the registry current
    /// from device notifications, reporting each change as a
    /// `device.connected` / `device.disconnected` event — normal events,
    /// never errors, never polling (`stream` sessions and
    /// `devices --watch` both consume them).
    ///
    /// Throws if the registry rejects an input (a duplicate identifier);
    /// the host's loader reports that as an `error` event and the engine
    /// keeps running.
    public func activate(in context: PlugInContext) async throws {
        for device in enumerateDevices() {
            try await context.inputs.register(Self.makeInput(for: device))
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
        let reporter = DeviceEventReporter(changes: deviceChanges(), makeInput: Self.makeInput)
        let eventBus = context.eventBus
        let inputs = context.inputs
        Task {
            await reporter.run(on: eventBus, inputs: inputs)
        }
    }

    /// The plug-in's input factory: a camera or microphone input over a
    /// discovered device, used at activation and for later connections.
    private static func makeInput(for device: CaptureDevice) -> any Input {
        device.kind == .camera ? CameraInput(device: device) : MicrophoneInput(device: device)
    }

    /// Reads the connected cameras and microphones from AVFoundation.
    ///
    /// Discovery does not capture, so it needs no TCC authorization. It
    /// reports current state at the moment of the call — device connection
    /// and disconnection afterwards is a normal event, not an error.
    private static func connectedDevices() -> [CaptureDevice] {
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        let microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        return cameras.map { CaptureDevice(uniqueID: $0.uniqueID, name: $0.localizedName, kind: .camera) }
            + microphones.map { CaptureDevice(uniqueID: $0.uniqueID, name: $0.localizedName, kind: .microphone) }
    }
}
