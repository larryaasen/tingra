//
//  StreamStatusToolTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-08-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraMCP

/// The `stream_status` tool's argument handling: the session id is optional
/// (an omitted or null id addresses the active stream — MCP.md, "Tool
/// surface"), and a present-but-non-string id is a malformed call, never a
/// silent omission.
@Suite("StreamStatusTool")
struct StreamStatusToolTests {
    /// A coordinator with nothing active — enough for the argument-handling
    /// paths this suite exercises; the session-addressing behavior itself is
    /// covered by the coordinator's own suite.
    private func makeIdleCoordinator() -> StreamCoordinator {
        StreamCoordinator(
            inputs: InputRegistry(),
            outputs: OutputRegistry(),
            status: StatusSink(),
            eventBus: EventBus(),
            clock: FinishingClock(),
            defaults: StreamDefaults(cameraID: { nil }, microphoneID: { nil })
        )
    }

    @Test("a call with no arguments reports the idle state on an idle engine")
    func noArgumentsReportsIdle() async throws {
        let tool = StreamStatusTool(coordinator: makeIdleCoordinator())
        let report = try await tool.call(.object([:]))
        #expect(report == .object(["state": .string("idle")]))
    }

    @Test("a null sessionId reads as omitted")
    func nullSessionIdReadsAsOmitted() async throws {
        let tool = StreamStatusTool(coordinator: makeIdleCoordinator())
        let report = try await tool.call(.object(["sessionId": .null]))
        #expect(report == .object(["state": .string("idle")]))
    }

    @Test("a non-string sessionId returns an invalidArgument error")
    func nonStringSessionIdReturnsAnError() async throws {
        let tool = StreamStatusTool(coordinator: makeIdleCoordinator())
        do {
            _ = try await tool.call(.object(["sessionId": .int(7)]))
            Issue.record("the call should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
        }
    }

    @Test("an explicit id that names no session returns an invalidArgument error")
    func unknownExplicitIdReturnsAnError() async throws {
        let tool = StreamStatusTool(coordinator: makeIdleCoordinator())
        do {
            _ = try await tool.call(.object(["sessionId": .string("stream-nope")]))
            Issue.record("the call should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
        }
    }
}
