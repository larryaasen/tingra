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
///
/// The session id may be omitted: with one active stream at a time (MCP.md,
/// "Sessions and concurrency") there is never ambiguity to resolve, so an
/// agent that reconnected to a daemon mid-show — or was simply asked "what's
/// the stream status?" — gets an answer without holding an id. An idle
/// engine answers `{"state": "idle"}` rather than erroring: "nothing is
/// streaming" is a truthful status, not a failure.
///
/// The session's own `state` is derived from its destination legs (see
/// ``StreamCoordinator/sessionState(ofLegs:)``), so the headline and the legs
/// can never disagree — it answers "is this stream delivering?", which is what
/// an agent asked "is my stream up?" needs.
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
        + "for an active stream. Omit sessionId to address the active stream, whatever its id. 'state' "
        + "says whether the stream is delivering: 'idle' (nothing is running), 'pending' (starting, no "
        + "destination has reported yet), 'live' (delivering), 'degraded' (a destination is down or "
        + "reconnecting while others deliver), or 'lost' (every destination ended). Each destination of "
        + "a fanned-out stream reports its own state alongside its last counters, which stay put when it "
        + "stops delivering — 'state' says whether they are current."

    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "sessionId": .object([
                "type": .string("string"),
                "description": .string(
                    "The session id returned by stream_start. Omit to address the active stream."),
            ])
        ]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        try await coordinator.statusReport(sessionId: ArgumentReader(arguments).sessionId(tool: name))
    }
}
