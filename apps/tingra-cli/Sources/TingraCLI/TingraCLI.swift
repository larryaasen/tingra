//
//  TingraCLI.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser

/// The `tingra-cli` root command (see CLI.md, "Command structure").
///
/// Subcommand rollout follows the roadmap: `devices` completes in step 1
/// (`--watch` in step 2), `stream` spans steps 2–3 (`--dry-run` now, going
/// live at step 3), `probe` arrives with streaming, and `serve`/`mcp` land
/// in step 4.
@main
struct TingraCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tingra-cli",
        abstract: "Command line streaming for Tingra.",
        version: TingraCLIVersion.current,
        subcommands: [
            Stream.self,
            Devices.self,
            Version.self,
        ]
    )
}
