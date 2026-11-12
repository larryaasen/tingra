//
//  PaneRecoveryTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

@Suite("PaneRecovery")
struct PaneRecoveryTests {
    @Test("a new pane has no errors on record")
    func startsClean() {
        #expect(PaneRecovery().failures == 0)
        #expect(PaneRecovery() == PaneRecovery())
    }

    @Test("each error in a row waits twice as long as the last: 1, 2, 4, then 8 seconds")
    func waitsDouble() {
        var recovery = PaneRecovery()
        #expect(recovery.sceneFailed() == .retry(after: .seconds(1)))
        #expect(recovery.sceneFailed() == .retry(after: .seconds(2)))
        #expect(recovery.sceneFailed() == .retry(after: .seconds(4)))
        #expect(recovery.sceneFailed() == .retry(after: .seconds(8)))
        #expect(recovery.failures == 4)
    }

    @Test("the error after the last retry gives up, and so does every one after it")
    func givesUpAfterTheLastRetry() {
        var recovery = PaneRecovery()
        for _ in 0..<PaneRecovery.maximumRetries {
            #expect(recovery.sceneFailed() != .giveUp)
        }
        #expect(recovery.sceneFailed() == .giveUp)
        #expect(recovery.sceneFailed() == .giveUp)
    }

    @Test("a scene coming up ends the run, so the next error starts from one second")
    func activationResets() {
        var recovery = PaneRecovery()
        _ = recovery.sceneFailed()
        _ = recovery.sceneFailed()
        _ = recovery.sceneFailed()

        recovery.sceneActivated()

        #expect(recovery.failures == 0)
        #expect(recovery.sceneFailed() == .retry(after: .seconds(1)))
    }

    @Test("two panes with different runs of errors are not equal")
    func differentRunsDiffer() {
        var one = PaneRecovery()
        _ = one.sceneFailed()
        #expect(one != PaneRecovery())
    }
}
