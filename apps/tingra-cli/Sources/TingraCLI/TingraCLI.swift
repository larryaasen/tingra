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
/// Subcommand rollout follows the roadmap: `devices` completed in step 1
/// (`--watch` in step 2), `stream` and `probe` went live in step 3, and
/// `serve`/`mcp` land in step 4.
@main
struct TingraCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tingra-cli",
        abstract: "Command line streaming for Tingra.",
        version: TingraCLIVersion.current,
        subcommands: [
            Stream.self,
            Devices.self,
            Probe.self,
            Serve.self,
            Mcp.self,
            Version.self,
        ]
    )
}
