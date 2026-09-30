//
//  DaemonEngine.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-09-29.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraCapturePlugIns
import TingraEventBus
import TingraGeneratorPlugIns
import TingraHost
import TingraMCP
import TingraOutputPlugIns
import TingraPlugInKit
import TingraRecordingPlugIns

/// The engine `serve` runs, assembled in one place: the registries, the
/// status sink, the stream coordinator, and the compiled-in plug-ins.
///
/// `serve` runs it, and `plug-ins` builds one against scratch registries to
/// list exactly the plug-ins the daemon would load (PLUGINS.md, Decision 35),
/// so the two can never disagree about what is compiled in.
struct DaemonEngine {
    /// The master clock (CLOCK.md).
    let clock: HostClock

    /// The registered inputs.
    let inputs: InputRegistry

    /// The registered outputs.
    let outputs: OutputRegistry

    /// The registered MCP tools.
    let tools: ToolRegistry

    /// The sink that feeds `stream_status` and the MCP notifications. The
    /// caller attaches it to the bus when it serves.
    let status: StatusSink

    /// The stream session owner the control tools drive.
    let coordinator: StreamCoordinator

    /// The plug-ins compiled into `serve`, in activation order: first-party
    /// plug-ins load through the same path a third party's does, including
    /// the control tools that expose the CLI surface as MCP tools (MCP.md,
    /// "Tool surface").
    let compiledInPlugIns: [any PlugIn]

    /// The context every plug-in activates against.
    let context: PlugInContext

    /// Assembles the engine on a bus.
    ///
    /// - Parameter eventBus: The bus every part reports on.
    init(eventBus: EventBus) {
        // Assemble the engine: registries, the tool registry, the status sink
        // that feeds stream_status and the MCP notifications, and the clock.
        let clock = HostClock()
        let inputs = InputRegistry(eventBus: eventBus)
        let outputs = OutputRegistry()
        let tools = ToolRegistry()
        let status = StatusSink()

        // The operator's saved destinations, so an agent can name "my Twitch"
        // instead of carrying a URL and key (DESTINATIONS.md). The daemon
        // reads its own keychain group, not the app's: sharing one needs a
        // restricted entitlement this bare executable cannot carry (0.1.2 —
        // see the entitlements file). So names and URLs resolve, and a key
        // filed in the app is reported absent with the reason in the message.
        let destinations = DestinationStore(eventBus: eventBus)

        let coordinator = StreamCoordinator(
            inputs: inputs,
            outputs: outputs,
            status: status,
            eventBus: eventBus,
            clock: clock,
            defaults: StreamDefaults(
                cameraID: { SystemDefaultInputs.cameraID },
                microphoneID: { SystemDefaultInputs.microphoneID }
            ),
            destinationStore: destinations
        )

        self.clock = clock
        self.inputs = inputs
        self.outputs = outputs
        self.tools = tools
        self.status = status
        self.coordinator = coordinator
        self.compiledInPlugIns = [
            AVFoundationCapturePlugIn(),
            GeneratorPlugIn(),
            HaishinKitOutputPlugIn(),
            RecordingPlugIn(),
            ControlToolsPlugIn(
                coordinator: coordinator, inputs: inputs, outputs: outputs, destinations: destinations),
        ]
        self.context = PlugInContext(
            eventBus: eventBus, clock: clock, inputs: inputs, outputs: outputs, effects: EffectRegistry(),
            tools: tools)
    }

    /// Activates the compiled-in plug-ins, then the plug-in bundles
    /// installed in the plug-in folders (PLUGINS.md, Decision 27).
    ///
    /// - Parameter bundleLoader: What finds and admits the bundles.
    /// - Returns: What activated, what the scan found, and the report.
    @discardableResult
    func activatePlugIns(bundlesFrom bundleLoader: PlugInBundleLoader) async -> PlugInActivation {
        await PlugInLoader().activate(compiledInPlugIns, thenBundlesFrom: bundleLoader, in: context)
    }
}
