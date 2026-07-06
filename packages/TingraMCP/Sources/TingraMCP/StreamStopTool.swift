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
        "Cleanly stop an active stream by its session id, flushing compression and closing the connection."

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
            throw ToolError(identifier: .invalidArgument, message: "stream_stop requires a string 'sessionId'.")
        }
        return try await coordinator.stop(sessionId: sessionId)
    }
}
