//
//  StreamStatusTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApp

/// Which stream states hold a session — the rule behind the locked
/// destination fields, the refused format change and project switch, and
/// Start Streaming refusing a second session.
@Suite("StreamStatus")
struct StreamStatusTests {
    /// Every state a session is in flight for, stopping included.
    private nonisolated static let active: [EngineModel.StreamStatus] = [
        .starting, .live, .reconnecting(attempt: 1, maxAttempts: 5), .stopping,
    ]

    /// Every state with no session.
    private nonisolated static let inactive: [EngineModel.StreamStatus] = [.idle, .stopped, .error("refused")]

    @Test("a starting, live, reconnecting, or stopping stream holds a session", arguments: active)
    func activeStates(status: EngineModel.StreamStatus) {
        #expect(status.isActive)
    }

    @Test("an idle, stopped, or failed stream holds none", arguments: inactive)
    func inactiveStates(status: EngineModel.StreamStatus) {
        #expect(!status.isActive)
    }

    @Test("stopping compares equal to itself and unequal to live and stopped")
    func stoppingEquality() {
        #expect(EngineModel.StreamStatus.stopping == .stopping)
        #expect(EngineModel.StreamStatus.stopping != .live)
        #expect(EngineModel.StreamStatus.stopping != .stopped)
    }
}
