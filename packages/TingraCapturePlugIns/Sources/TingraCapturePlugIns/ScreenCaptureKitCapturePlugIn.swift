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
/// only capturing a display does. Display **hot-plug** is reported too (added
/// 2026-07-28): a monitor plugged in or removed while running keeps the
/// registry current and reaches the bus as the same
/// `device.connected`/`device.disconnected` events the AVFoundation plug-in
/// emits, with `kind=display` — one vocabulary for every input, so
/// `devices --watch` and the app's device-list refresh need no special case
/// (see ``DisplayEventReporter``).
public struct ScreenCaptureKitCapturePlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.capture.screencapturekit")

    /// The plug-in's user-facing name.
    public let name = "ScreenCaptureKit Capture"

    /// Enumerates the connected displays. Production reads CoreGraphics;
    /// tests inject fixtures so no display or Screen Recording authorization
    /// is needed on runners.
    private let enumerateDisplays: @Sendable () -> [DisplayDevice]

    /// The display connection/disconnection stream. Production observes
    /// CoreGraphics' reconfiguration callback; tests inject a scripted
    /// stream.
    private let displayChanges: @Sendable () -> AsyncStream<DisplayChange>

    /// Creates the production plug-in, enumerating real CoreGraphics
    /// displays and observing real display reconfigurations.
    public init() {
        self.init(enumerateDisplays: DisplayDiscovery.connectedDisplays)
    }

    /// Creates a plug-in over an injected display enumerator and change
    /// stream (the test seams).
    init(
        enumerateDisplays: @escaping @Sendable () -> [DisplayDevice],
        displayChanges: @escaping @Sendable () -> AsyncStream<DisplayChange> = { DisplayEventReporter.liveChanges() }
    ) {
        self.enumerateDisplays = enumerateDisplays
        self.displayChanges = displayChanges
    }

    /// Registers one input per connected display, reporting each discovery
    /// as a `trace` event, then keeps the registry current from display
    /// reconfigurations, reporting each change as a `device.connected` /
    /// `device.disconnected` event — normal events, never errors, never
    /// polling.
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

        // Fire and forget for the life of the process, exactly as the
        // AVFoundation plug-in does: the reporter ends when its change stream
        // does, and there is no deactivation hook yet — plug-ins live as long
        // as the engine.
        let eventBus = context.eventBus
        let reporter = DisplayEventReporter(
            changes: displayChanges(),
            makeInput: { DisplayInput(display: $0) }
        )
        let inputs = context.inputs
        Task {
            await reporter.run(on: eventBus, inputs: inputs)
        }
    }
}
