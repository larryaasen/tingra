//
//  StreamStatusTool.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The `stream_status` tool: the connection state and latest delivery
/// counters (bitrate, fps, bytes sent, elapsed) for a stream, mirroring the
/// `--json` status events (CLI.md). Reads live data from the status sink —
/// not a poll — and status changes also arrive as notifications.
struct StreamStatusTool: Tool {
    /// The coordinator holding the active stream.
    private let coordinator: StreamCoordinator

    /// Creates the tool over the shared coordinator.
    init(coordinator: StreamCoordinator) {
        self.coordinator = coordinator
    }

    let name = "stream_status"
    let title = "Stream Status"
    let description =
        "Report the connection state and latest delivery counters (bitrate, fps, bytesSent, elapsed) "
        + "for an active stream by its session id."

    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([.string("sessionId")]),
        "properties": .object([
            "sessionId": .object([
                "type": .string("string"),
                "description": .string("The session id returned by stream_start."),
            ])
        ]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        guard let sessionId = arguments["sessionId"]?.stringValue else {
            throw ToolError(identifier: .invalidArgument, message: "stream_status requires a string 'sessionId'.")
        }
        return try await coordinator.statusReport(sessionId: sessionId)
    }
}
