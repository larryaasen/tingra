//
//  Devices.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser

/// The kinds of inputs `devices` can list.
enum DeviceType: String, ExpressibleByArgument, CaseIterable {
    case camera
    case mic
    case all
}

/// `tingra-cli devices` — input discovery (see CLI.md).
///
/// Outline status: the command surface is in place; discovery itself lands
/// with the camera and microphone input plug-ins (roadmap steps 1–2), which
/// will register into the host's `InputRegistry` and be listed here.
struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available cameras, microphones, and their IDs."
    )

    @Option(help: "Limit the listing to one input type: camera, mic, or all.")
    var type: DeviceType = .all

    @Flag(help: "Emit stable identifiers as JSON for scripting.")
    var json = false

    func run() async throws {
        // Input discovery arrives with the first input plug-ins; until then
        // the honest answer is that nothing is registered yet. Exit 70
        // (internal error, per the CLI.md exit code table) — the flags were
        // valid, so this is not a usage error.
        print("tingra-cli devices: input discovery is not implemented yet — it lands with the first input plug-ins (roadmap steps 1-2).")
        throw ExitCode(70)
    }
}
