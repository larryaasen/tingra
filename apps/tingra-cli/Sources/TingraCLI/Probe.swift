//
//  Probe.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TingraEventBus
import TingraHost
import TingraOutputPlugIns
import TingraPlugInKit

/// `tingra-cli probe` — validate a destination URL/key without going live
/// (CLI.md): the real connection and publish handshake, then an immediate
/// disconnect, so scripts can check credentials before an event.
struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate a destination URL/key without going live."
    )

    @Option(help: "RTMP(S) destination URL to validate, e.g. rtmp://live.twitch.tv/app.")
    var url: String

    @Option(help: "Stream key to validate. Prefer --key-env or --key-stdin in scripts.")
    var key: String?

    @Option(help: "Read the stream key from this environment variable.")
    var keyEnv: String?

    @Flag(help: "Read the stream key from standard input.")
    var keyStdin = false

    @Flag(help: "Emit newline delimited JSON events instead of human readable output.")
    var json = false

    @Flag(help: "Show every event group on the console.")
    var verbose = false

    @Flag(help: "Show errors only on the console.")
    var quiet = false

    @Option(help: "Also write logs to a file.")
    var logFile: String?

    /// Flag/option validation — syntactic and cross-flag rules; exit 64 on
    /// failure (CLI.md exit codes).
    func validate() throws {
        guard let destination = URL(string: url), let scheme = destination.scheme?.lowercased() else {
            throw ValidationError("The --url value is not a valid URL: '\(url)'.")
        }
        guard ["rtmp", "rtmps", "srt"].contains(scheme) else {
            throw ValidationError(
                "The --url scheme '\(scheme)' is not supported; use rtmp://, rtmps://, or srt://."
            )
        }
        let keySources = [key != nil, keyEnv != nil, keyStdin].count(where: { $0 })
        guard keySources <= 1 else {
            throw ValidationError("Pass at most one of --key, --key-env, and --key-stdin.")
        }
        if let keyEnv {
            guard let value = ProcessInfo.processInfo.environment[keyEnv], !value.isEmpty else {
                throw ValidationError("The --key-env variable '\(keyEnv)' is not set (or is empty).")
            }
        }
        guard !(verbose && quiet) else {
            throw ValidationError("--verbose and --quiet conflict.")
        }
    }

    func run() async throws {
        let eventBus = EventBus()
        let consoleGroups: Set<EventGroup> =
            if quiet {
                [.error]
            } else if verbose {
                Set(EventGroup.allCases)
            } else if json {
                ConsoleSink.defaultGroups
            } else {
                [.error]
            }
        let consoleTask = eventBus.attach(ConsoleSink(mode: json ? .json : .human, groups: consoleGroups))
        // Skipped when standard error is a terminal (see EVENTS.md, "OSLog
        // sink"); it remains the system of record for non-interactive runs.
        let osLogTask = OSLogAttachment.attachIfNeeded(to: eventBus)
        let fileTask = logFile.map { eventBus.attach(FileSink(path: $0)) }

        /// Drains every sink so no buffered event is lost before exit.
        func drainSinks() async {
            eventBus.shutdown()
            await consoleTask.value
            if let osLogTask {
                await osLogTask.value
            }
            if let fileTask {
                await fileTask.value
            }
        }

        // Only the output plug-in loads — a probe touches no camera, no
        // microphone, and therefore no TCC authorization.
        let outputs = OutputRegistry()
        let context = PlugInContext(
            eventBus: eventBus,
            clock: HostClock(),
            inputs: InputRegistry(),
            outputs: outputs,
            effects: EffectRegistry(),
            tools: ToolRegistry()
        )
        await PlugInLoader().activate([HaishinKitOutputPlugIn()], in: context)

        do {
            guard let destinationURL = URL(string: url), let scheme = destinationURL.scheme?.lowercased()
            else {
                throw StreamingServiceError.unsupportedDestination("The --url value is not a valid URL.")
            }
            guard let provider = await outputs.provider(forScheme: scheme) else {
                throw StreamingServiceError.unsupportedDestination(
                    """
                    No registered output serves '\(scheme)://' destinations in v1 — SRT output arrives \
                    at roadmap step 8. Probe an rtmp:// or rtmps:// destination.
                    """
                )
            }
            let streamKey = try StreamKey.read(option: key, environmentVariable: keyEnv, stdin: keyStdin)
            let destination = Destination(url: destinationURL, streamKey: streamKey)

            // The handshake: connect and publish, then disconnect —
            // nothing is sent. Services (and the simulator) reject a bad
            // stream key not with an RTMP error but by closing the
            // connection just after accepting the publish, so a short
            // confirmation window watches for that close before the
            // destination is declared valid.
            let service = provider.makeStreamingService(configuration: StreamConfiguration())
            try await service.start(to: destination)
            let lost = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await event in service.events {
                        if case .connectionLost = event {
                            return true
                        }
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            await service.stop()
            if lost {
                throw StreamingServiceError.connectionRejected(
                    """
                    The destination accepted the handshake but closed the connection immediately — \
                    with most services that means the stream key was rejected.
                    """
                )
            }

            eventBus.event("probe.succeeded", domain: .output, params: ["url": .string(url)])
            if !json {
                print("The destination accepted the connection\(streamKey == nil ? "" : " and stream key").")
            }
            await drainSinks()
        } catch {
            let identifier = Self.identifier(for: error)
            eventBus.error(
                "probe",
                domain: .output,
                params: [
                    "identifier": .string(identifier.rawValue),
                    "message": .string(String(describing: error)),
                ]
            )
            await drainSinks()
            throw ExitCode(identifier.exitCode)
        }
    }

    /// The stable error identifier for a probe failure.
    private static func identifier(for error: any Error) -> ErrorIdentifier {
        switch error {
        case let serviceError as StreamingServiceError:
            return serviceError.identifier
        case let keyError as StreamKeyError:
            return keyError.identifier
        default:
            return .pipelineError
        }
    }
}
