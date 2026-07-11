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
/// Two run modes and two setup actions:
/// - **Manual mode** (`serve`): creates its own socket and runs in the
///   foreground, for development and debugging.
/// - **Socket-activated mode** (`serve`, when launched by launchd): adopts the
///   launchd-owned listening socket and idle-exits when quiet — the product
///   path, so TCC prompts name Tingra (MCP.md, "Lifecycle").
/// - **`serve --install` / `--uninstall`**: register or remove the launchd
///   LaunchAgent that provides socket activation. Run once after install (the
///   Homebrew formula points users here).
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the persistent engine process (the daemon)."
    )

    @Flag(help: "Install and load the launchd LaunchAgent, then exit.")
    var install = false

    @Flag(help: "Unload and remove the launchd LaunchAgent, then exit.")
    var uninstall = false

    @Option(help: "The tingra-cli path written into the LaunchAgent (--install). Defaults to this executable.")
    var program: String?

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
        guard !(install && uninstall) else { throw ValidationError("--install and --uninstall conflict.") }
    }

    func run() async throws {
        if uninstall {
            try runUninstall()
            return
        }
        if install {
            try runInstall()
            return
        }
        try await runDaemon()
    }

    // MARK: - LaunchAgent setup

    /// Installs and loads the LaunchAgent (`serve --install`). One-shot setup:
    /// no engine is booted.
    private func runInstall() throws {
        let socketPath = socket ?? SocketLocation.path
        let programPath = try resolvedProgramPath()
        let agent = LaunchAgent(programPath: programPath, socketPath: socketPath)
        do {
            // launchd creates the socket in this directory, so it must exist
            // and be 0700 before the agent loads (standard path only; a custom
            // --socket path is the caller's to place).
            if socket == nil { try SocketLocation.prepareDirectory() }
            try agent.install()
        } catch {
            printError("serve --install: \(error)")
            throw ExitCode(ErrorIdentifier.pipelineError.exitCode)
        }
        print("Installed and loaded the Tingra daemon LaunchAgent (\(LaunchAgent.label)).")
        print("  Program: \(programPath)")
        print("  Socket:  \(socketPath)")
        print("The daemon now starts automatically on the first connection; no need to run `serve` by hand.")
    }

    /// Unloads and removes the LaunchAgent (`serve --uninstall`).
    private func runUninstall() throws {
        do {
            try LaunchAgent.uninstall()
        } catch {
            printError("serve --uninstall: \(error)")
            throw ExitCode(ErrorIdentifier.pipelineError.exitCode)
        }
        print("Removed the Tingra daemon LaunchAgent (\(LaunchAgent.label)).")
    }

    /// Resolves the absolute `tingra-cli` path to record in the LaunchAgent.
    /// Prefers an explicit `--program`, then the absolute path this process
    /// was invoked as (a Homebrew `bin` symlink stays stable across upgrades),
    /// then the resolved executable path.
    ///
    /// - Throws: An argument error (exit 64) if no absolute path can be found,
    ///   since launchd requires an absolute `ProgramArguments` path.
    private func resolvedProgramPath() throws -> String {
        if let program {
            guard program.hasPrefix("/") else {
                printError("serve --install: --program must be an absolute path (launchd requires one).")
                throw ExitCode(ErrorIdentifier.invalidArgument.exitCode)
            }
            return program
        }
        if let argv0 = CommandLine.arguments.first, argv0.hasPrefix("/") {
            return argv0
        }
        if let path = Bundle.main.executablePath, path.hasPrefix("/") {
            return path
        }
        printError(
            "serve --install: could not determine an absolute tingra-cli path; pass --program /path/to/tingra-cli.")
        throw ExitCode(ErrorIdentifier.invalidArgument.exitCode)
    }

    /// Writes a line to standard error (setup diagnostics; the socket, not
    /// stdout/stderr, is the daemon's MCP channel).
    private func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: - Daemon

    /// Runs the daemon: manual mode (its own socket) or, when launched by
    /// launchd, socket-activated mode (adopting the launchd-owned socket).
    private func runDaemon() async throws {
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

        let info = DaemonInfo(name: "tingra", version: TingraCLIVersion.current)
        let timeout: Duration? = idleTimeout > 0 ? .seconds(idleTimeout) : nil
        let socketPath = socket ?? SocketLocation.path
        do {
            let daemon = try makeDaemon(
                tools: tools, status: status, coordinator: coordinator,
                eventBus: eventBus, info: info, idleTimeout: timeout, socketPath: socketPath)

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

    /// Builds the daemon, adopting the launchd-owned socket when the process
    /// was socket-activated and otherwise binding its own (manual mode). An
    /// explicit `--socket` always means manual mode.
    private func makeDaemon(
        tools: ToolRegistry,
        status: StatusSink,
        coordinator: StreamCoordinator,
        eventBus: EventBus,
        info: DaemonInfo,
        idleTimeout: Duration?,
        socketPath: String
    ) throws -> Daemon {
        if socket == nil, let adopted = LaunchdSocket.activate() {
            return Daemon(
                listeningDescriptor: adopted,
                tools: tools,
                status: status,
                coordinator: coordinator,
                eventBus: eventBus,
                info: info,
                idleTimeout: idleTimeout
            )
        }
        // Only prepare the standard directory (0700); a custom --socket path
        // is the caller's to place.
        if socket == nil { try SocketLocation.prepareDirectory() }
        return try Daemon.manual(
            socketPath: socketPath,
            tools: tools,
            status: status,
            coordinator: coordinator,
            eventBus: eventBus,
            info: info,
            idleTimeout: idleTimeout
        )
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
