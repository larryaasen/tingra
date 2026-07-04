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
/// and microphones as inputs with stable identifiers.
///
/// AVFoundation is imported only here, behind the `Input` seam — nothing
/// downstream of the registry knows which framework produced these inputs
/// (see ARCHITECTURE.md, "Dependency Injection Pattern").
///
/// Roadmap status: input discovery (step 1). The registered inputs carry
/// stable identifiers, names, and kinds, but capture itself arrives with
/// roadmap step 2.
public struct AVFoundationCapturePlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.capture.avfoundation")

    /// The plug-in's user-facing name.
    public let name = "AVFoundation Capture"

    /// Enumerates the connected capture devices. Production reads
    /// AVFoundation's discovery sessions; tests inject fixtures so no
    /// camera, microphone, or TCC authorization is needed on runners.
    private let enumerateDevices: @Sendable () -> [CaptureDevice]

    /// Creates the production plug-in, enumerating real AVFoundation
    /// devices.
    public init() {
        self.init(enumerateDevices: Self.connectedDevices)
    }

    /// Creates a plug-in over an injected device enumerator (the test seam).
    init(enumerateDevices: @escaping @Sendable () -> [CaptureDevice]) {
        self.enumerateDevices = enumerateDevices
    }

    /// Registers one input per connected camera and microphone, reporting
    /// each discovery as a `trace` event.
    ///
    /// Throws if the registry rejects an input (a duplicate identifier);
    /// the host's loader reports that as an `error` event and the engine
    /// keeps running.
    public func activate(in context: PlugInContext) async throws {
        for device in enumerateDevices() {
            try await context.inputs.register(CaptureDeviceInput(device: device))
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
