//
//  Devices.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TingraCapturePlugIns
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// The kinds of inputs `devices` can list.
enum DeviceType: String, ExpressibleByArgument, CaseIterable {
    case camera
    case mic
    case all
}

/// `tingra-cli devices` — input discovery (see CLI.md).
///
/// Activates the capture plug-ins through the host's loader, then lists the
/// registered inputs: a human readable table by default, the stable
/// `devices --json` document under `--json`. Reports current state at the
/// moment of the call — device connection and disconnection is a normal
/// event, not an error. `--watch` then stays alive, printing one line per
/// `device.connected` / `device.disconnected` event through the console
/// sink until Ctrl-C / SIGTERM.
struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available cameras, microphones, and their IDs."
    )

    @Option(help: "Limit the listing to one input type: camera, mic, or all.")
    var type: DeviceType = .all

    @Flag(help: "Emit stable identifiers as JSON for scripting.")
    var json = false

    @Flag(help: "Keep running, printing device connection and disconnection events until Ctrl-C.")
    var watch = false

    func run() async throws {
        let eventBus = EventBus()
        // The listing itself is the command result on standard output; the
        // console sink carries only errors here, so `devices --json | jq`
        // sees one JSON document on a clean run. OSLog is skipped when
        // standard error is a terminal — the OS's own terminal mirror
        // already echoes this process's events there, so attaching would
        // double them (see EVENTS.md, "OSLog sink"); it remains the system
        // of record for non-interactive runs.
        let consoleTask = eventBus.attach(ConsoleSink(mode: json ? .json : .human, groups: [.error]))
        let osLogTask = OSLogAttachment.attachIfNeeded(to: eventBus)

        let registry = InputRegistry()
        let context = PlugInContext(
            eventBus: eventBus,
            clock: HostClock(),
            inputs: registry,
            outputs: OutputRegistry(),
            effects: EffectRegistry(),
            tools: ToolRegistry()
        )
        await PlugInLoader().activate([AVFoundationCapturePlugIn()], in: context)

        let listing = await DeviceList(inputs: registry.allInputs, type: type)
        if json {
            let encoder = JSONEncoder()
            // Under --watch the document must be the single first line of
            // the NDJSON stream; standalone it stays pretty for humans
            // running `devices --json` by hand.
            encoder.outputFormatting =
                watch
                ? [.sortedKeys, .withoutEscapingSlashes]
                : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(listing), as: UTF8.self))
        } else {
            print(listing.table)
        }

        var watchTask: Task<Void, Never>?
        if watch {
            // Live events flow through the console sink like everywhere
            // else — no bespoke output path (CLI.md). Attached after the
            // listing so the document stays first; --type narrows device
            // events the same way it narrows the listing.
            watchTask = eventBus.attach(
                ConsoleSink(
                    mode: json ? .json : .human,
                    groups: [.error, .event],
                    isIncluded: Self.deviceEventFilter(for: type)
                )
            )
            // In human mode each reported change is followed by the
            // refreshed listing on standard output — the capture plug-in
            // keeps the registry current, so rebuilding from it reflects
            // the change. Under --json the initial document is not
            // re-emitted; scripts fold the event lines into it (CLI.md).
            let deviceEvents = eventBus.events()
            let isReportable = Self.deviceEventFilter(for: type)
            // Ctrl-C / SIGTERM ends the loop below by shutting the bus
            // down, which finishes every subscription — a clean stop,
            // exit 0 (CLI.md).
            let signalTask = Task {
                await TerminationSignal.wait()
                eventBus.shutdown()
            }
            for await event in deviceEvents where event.name.hasPrefix("device.") && isReportable(event) {
                guard !json else { continue }
                let refreshed = await DeviceList(inputs: registry.allInputs, type: type)
                print("\n" + refreshed.table)
            }
            await signalTask.value
        }

        // Drain the sinks before exiting so no buffered event is lost.
        eventBus.shutdown()
        await consoleTask.value
        if let osLogTask {
            await osLogTask.value
        }
        if let watchTask {
            await watchTask.value
        }
    }

    /// The `--type` refinement for watch mode: device events must match
    /// the requested kind; every other event passes untouched.
    static func deviceEventFilter(for type: DeviceType) -> @Sendable (EventBusEvent) -> Bool {
        { event in
            guard event.name.hasPrefix("device."), let kind = event.params?["kind"] else { return true }
            switch type {
            case .all: return true
            case .camera: return kind == .string(InputKind.camera.rawValue)
            case .mic: return kind == .string(InputKind.microphone.rawValue)
            }
        }
    }
}
