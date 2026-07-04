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
/// event, not an error.
struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available cameras, microphones, and their IDs."
    )

    @Option(help: "Limit the listing to one input type: camera, mic, or all.")
    var type: DeviceType = .all

    @Flag(help: "Emit stable identifiers as JSON for scripting.")
    var json = false

    func run() async throws {
        let eventBus = EventBus()
        // The listing itself is the command result on standard output; the
        // console sink carries only errors here, so `devices --json | jq`
        // sees one JSON document on a clean run. The OSLog sink is the
        // always-on system of record (EVENTS.md) and gets everything.
        let consoleTask = eventBus.attach(ConsoleSink(mode: json ? .json : .human, groups: [.error]))
        let osLogTask = eventBus.attach(OSLogSink())

        let registry = InputRegistry()
        let context = PlugInContext(eventBus: eventBus, clock: HostClock(), inputs: registry)
        await PlugInLoader().activate([AVFoundationCapturePlugIn()], in: context)

        let listing = await DeviceList(inputs: registry.allInputs, type: type)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(listing), as: UTF8.self))
        } else {
            print(listing.table)
        }

        // Drain the sinks before exiting so no buffered event is lost.
        eventBus.shutdown()
        await consoleTask.value
        await osLogTask.value
    }
}
