//
//  Serve.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TingraCapturePlugIns
import TingraEventBus
import TingraGeneratorPlugIns
import TingraHost
import TingraMCP
import TingraOutputPlugIns
import TingraPlugInKit

/// `tingra-cli serve` — run the persistent engine process, the daemon (CLI.md
/// and MCP.md). It owns the engine (session, pipeline, plug-ins, TCC
/// identity) and speaks MCP JSON-RPC over a per-user Unix domain socket,
/// serving each connection as an independent MCP session.
///
/// This is manual mode: `serve` creates its own socket and runs in the
/// foreground, for development and debugging. The launchd socket-activated
/// LaunchAgent (`serve --install`, MCP.md, "Lifecycle") is the product path
/// and lands in a follow-up; its design is recorded in MCP.md.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the persistent engine process (the daemon)."
    )

    @Option(help: "The Unix domain socket path. Defaults to the standard per-user location.")
    var socket: String?

    @Option(help: "Exit after this many seconds with no connections and nothing streaming (0 disables).")
    var idleTimeout: Int = 300

    @Flag(help: "Emit newline delimited JSON events instead of human readable logs.")
    var json = false

    @Flag(help: "Show every event group on the console.")
    var verbose = false

    @Flag(help: "Show errors only on the console.")
    var quiet = false

    @Option(help: "Also write logs to a file.")
    var logFile: String?

    /// Flag validation — exit 64 on failure (CLI.md exit codes).
    func validate() throws {
        guard idleTimeout >= 0 else { throw ValidationError("--idle-timeout cannot be negative.") }
        guard !(verbose && quiet) else { throw ValidationError("--verbose and --quiet conflict.") }
    }

    func run() async throws {
        let eventBus = EventBus()
        // The daemon's own stdout/stderr are not the MCP channel (the socket
        // is), so it logs like any other command: human lines to stderr, or
        // NDJSON under --json.
        let consoleGroups: Set<EventGroup> =
            if quiet {
                [.error]
            } else if verbose {
                Set(EventGroup.allCases)
            } else {
                ConsoleSink.defaultGroups
            }
        let consoleTask = eventBus.attach(ConsoleSink(mode: json ? .json : .human, groups: consoleGroups))
        // OSLog is the system of record for a launchd-managed (non-terminal)
        // daemon; a manual run in a terminal skips it to avoid the OS's own
        // terminal mirror doubling every line (see EVENTS.md, "OSLog sink").
        let osLogTask = OSLogAttachment.attachIfNeeded(to: eventBus)
        let fileTask = logFile.map { eventBus.attach(FileSink(path: $0)) }

        // Assemble the engine: registries, the tool registry, the status sink
        // that feeds stream_status and the MCP notifications, and the clock.
        let clock = HostClock()
        let inputs = InputRegistry()
        let outputs = OutputRegistry()
        let tools = ToolRegistry()
        let status = StatusSink()
        let statusTask = eventBus.attach(status)

        let coordinator = StreamCoordinator(
            inputs: inputs,
            outputs: outputs,
            status: status,
            eventBus: eventBus,
            clock: clock,
            defaults: StreamDefaults(
                cameraID: { SystemDefaultInputs.cameraID },
                microphoneID: { SystemDefaultInputs.microphoneID }
            )
        )

        // First-party plug-ins load through the same path a third party will
        // use, including the control tools that expose the CLI surface as MCP
        // tools (MCP.md, "Tool surface").
        let context = PlugInContext(eventBus: eventBus, clock: clock, inputs: inputs, outputs: outputs, tools: tools)
        await PlugInLoader().activate(
            [
                AVFoundationCapturePlugIn(),
                GeneratorPlugIn(),
                HaishinKitOutputPlugIn(),
                ControlToolsPlugIn(coordinator: coordinator, inputs: inputs, outputs: outputs),
            ],
            in: context
        )

        let socketPath = socket ?? SocketLocation.path
        do {
            // Only prepare the standard directory (0700); a custom --socket
            // path is the caller's to place.
            if socket == nil {
                try SocketLocation.prepareDirectory()
            }
            let daemon = try Daemon.manual(
                socketPath: socketPath,
                tools: tools,
                status: status,
                coordinator: coordinator,
                eventBus: eventBus,
                info: DaemonInfo(name: "tingra", version: TingraCLIVersion.current),
                idleTimeout: idleTimeout > 0 ? .seconds(idleTimeout) : nil
            )

            // Ctrl-C / SIGTERM stops the daemon cleanly, exit 0 (CLI.md).
            let signalTask = Task {
                await TerminationSignal.wait()
                await daemon.shutdown()
            }
            defer { signalTask.cancel() }

            eventBus.app("serve.started", domain: .control, params: ["socket": .string(socketPath)])
            await daemon.run()
        } catch {
            eventBus.error(
                "serve.start",
                domain: .control,
                params: [
                    "identifier": .string(ErrorIdentifier.pipelineError.rawValue),
                    "message": .string(String(describing: error)),
                ]
            )
            await status.shutdown()
            await drainSinks(
                eventBus: eventBus, console: consoleTask, osLog: osLogTask, file: fileTask, status: statusTask)
            throw ExitCode(ErrorIdentifier.pipelineError.exitCode)
        }

        await status.shutdown()
        await drainSinks(eventBus: eventBus, console: consoleTask, osLog: osLogTask, file: fileTask, status: statusTask)
    }

    /// Drains every sink so no buffered event is lost before exit.
    private func drainSinks(
        eventBus: EventBus,
        console: Task<Void, Never>,
        osLog: Task<Void, Never>?,
        file: Task<Void, Never>?,
        status: Task<Void, Never>
    ) async {
        eventBus.shutdown()
        await console.value
        await status.value
        if let osLog { await osLog.value }
        if let file { await file.value }
    }
}
