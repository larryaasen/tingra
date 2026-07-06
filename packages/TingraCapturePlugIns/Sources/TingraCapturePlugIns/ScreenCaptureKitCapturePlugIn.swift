//
//  ScreenCaptureKitCapturePlugIn.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The ScreenCaptureKit-backed capture plug-in: contributes the Mac's
/// displays as inputs with stable identifiers (their CoreGraphics UUIDs),
/// captured whole via ScreenCaptureKit.
///
/// ScreenCaptureKit is imported only behind the `Input` seam (in
/// ``DisplayInput``) — nothing downstream of the registry knows which
/// framework produced these inputs. Displays are a separate plug-in from
/// cameras and microphones (``AVFoundationCapturePlugIn``) because they use
/// a different framework and a different TCC permission (Screen Recording,
/// not Camera), matching ARCHITECTURE.md's capture services split.
///
/// Discovery lists displays through CoreGraphics, which needs no Screen
/// Recording authorization — like camera discovery, listing never prompts;
/// only capturing a display does. Display hot-plug events (a monitor added
/// or removed while running) are a later addition, like the capture
/// plug-in's `device.connected`/`device.disconnected` stream; for now the
/// registry reflects the displays present at activation.
public struct ScreenCaptureKitCapturePlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.capture.screencapturekit")

    /// The plug-in's user-facing name.
    public let name = "ScreenCaptureKit Capture"

    /// Enumerates the connected displays. Production reads CoreGraphics;
    /// tests inject fixtures so no display or Screen Recording authorization
    /// is needed on runners.
    private let enumerateDisplays: @Sendable () -> [DisplayDevice]

    /// Creates the production plug-in, enumerating real CoreGraphics
    /// displays.
    public init() {
        self.init(enumerateDisplays: DisplayDiscovery.connectedDisplays)
    }

    /// Creates a plug-in over an injected display enumerator (the test seam).
    init(enumerateDisplays: @escaping @Sendable () -> [DisplayDevice]) {
        self.enumerateDisplays = enumerateDisplays
    }

    /// Registers one input per connected display, reporting each discovery
    /// as a `trace` event.
    ///
    /// Throws if the registry rejects an input (a duplicate identifier); the
    /// host's loader reports that as an `error` event and the engine keeps
    /// running.
    public func activate(in context: PlugInContext) async throws {
        for display in enumerateDisplays() {
            try await context.inputs.register(DisplayInput(display: display))
            context.eventBus.trace(
                "input.discovered",
                domain: .capture,
                params: [
                    "id": .string(display.uniqueID),
                    "name": .string(display.name),
                    "kind": .string(InputKind.display.rawValue),
                ]
            )
        }
    }
}
