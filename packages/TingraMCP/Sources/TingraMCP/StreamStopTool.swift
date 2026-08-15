//
//  StreamStopTool.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The `stream_stop` tool: a clean stop of an active stream — flush
/// compression, close the connection — mirroring Ctrl-C on the CLI. Waits for
/// the orderly teardown before returning.
///
/// The session id may be omitted: with one active stream at a time (MCP.md,
/// "Sessions and concurrency") "stop the stream" is unambiguous, so an agent
/// that reconnected to a daemon mid-show can stop it without holding an id.
/// Stopping when nothing is active is an error (`noActiveStream`) — unlike
/// `stream_status`, there is no truthful way to have done the asked-for
/// thing.
struct StreamStopTool: Tool {
    /// The coordinator holding the active stream.
    private let coordinator: StreamCoordinator

    /// Creates the tool over the shared coordinator.
    init(coordinator: StreamCoordinator) {
        self.coordinator = coordinator
    }

    let name = "stream_stop"
    let title = "Stop Streaming"
    let description =
        "Cleanly stop an active stream, flushing compression, closing the connection, and finalizing any "
        + "recording. Omit sessionId to stop the active stream, whatever its id."

    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "sessionId": .object([
                "type": .string("string"),
                "description": .string(
                    "The session id returned by stream_start. Omit to stop the active stream."),
            ])
        ]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        try await coordinator.stop(sessionId: ArgumentReader(arguments).sessionId(tool: name))
    }
}
