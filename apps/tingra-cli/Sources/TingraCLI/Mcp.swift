//
//  Mcp.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TingraMCP
import TingraPlugInKit

/// `tingra-cli mcp` — the MCP entry point for agents (CLI.md, MCP.md). A
/// transparent stdio↔socket byte proxy with no protocol logic: it copies
/// bytes between the agent host (stdin/stdout) and the daemon socket, so an
/// agent host spawns `tingra-cli mcp` and talks MCP JSON-RPC to the
/// persistent daemon behind it.
///
/// Lifecycle mapping (MCP.md, "Thin edges"): stdin EOF closes the connection,
/// and the connection closing exits the process.
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "MCP entry point for agents (a thin stdio proxy to the daemon)."
    )

    @Option(help: "The daemon Unix domain socket path. Defaults to the standard per-user location.")
    var socket: String?

    func run() async throws {
        let socketPath = socket ?? SocketLocation.path
        do {
            try await StdioSocketProxy.run(socketPath: socketPath)
        } catch {
            // The daemon is not reachable — in the product path launchd would
            // have started it on connect; in manual mode the user must run
            // `tingra-cli serve` first. Report to stderr (never stdout, which
            // is the MCP channel) and exit with the connection-failed code.
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            throw ExitCode(ErrorIdentifier.connectionFailed.exitCode)
        }
    }
}
