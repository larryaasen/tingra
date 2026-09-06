//
//  TerminationReasonTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreServices
import Testing

@testable import TingraApp

@Suite("TerminationReason")
struct TerminationReasonTests {
    @Test("a quit event with no reason is a plain quit")
    func noReasonCodeIsQuit() {
        #expect(TerminationReason.forQuitEvent(reasonCode: nil) == .quit)
    }

    @Test("a reason code this app does not know is a plain quit")
    func unknownReasonCodeIsQuit() {
        #expect(TerminationReason.forQuitEvent(reasonCode: OSType(0x3F3F_3F3F)) == .quit)
    }

    @Test("each system reason code maps to its own case, both dialog and final forms alike")
    func eachSystemReasonCodeMaps() {
        #expect(TerminationReason.forQuitEvent(reasonCode: kAEQuitAll) == .quitAll)
        #expect(TerminationReason.forQuitEvent(reasonCode: kAELogOut) == .logout)
        #expect(TerminationReason.forQuitEvent(reasonCode: kAEReallyLogOut) == .logout)
        #expect(TerminationReason.forQuitEvent(reasonCode: kAERestart) == .restart)
        #expect(TerminationReason.forQuitEvent(reasonCode: kAEShowRestartDialog) == .restart)
        #expect(TerminationReason.forQuitEvent(reasonCode: kAEShutDown) == .shutdown)
        #expect(TerminationReason.forQuitEvent(reasonCode: kAEShowShutdownDialog) == .shutdown)
    }

    @Test("the raw values are the strings the event's reason param carries, and they are distinct")
    func rawValuesAreStableAndDistinct() {
        #expect(TerminationReason.application.rawValue == "application")
        #expect(TerminationReason.quit.rawValue == "quit")
        #expect(TerminationReason.quitAll.rawValue == "quitAll")
        #expect(TerminationReason.logout.rawValue == "logout")
        #expect(TerminationReason.restart.rawValue == "restart")
        #expect(TerminationReason.shutdown.rawValue == "shutdown")
        #expect(Set(TerminationReason.allCases.map(\.rawValue)).count == TerminationReason.allCases.count)
    }

    @Test("outside a quit Apple event the current reason is the application itself")
    func currentReasonWithNoQuitEventIsApplication() {
        // No Apple event is being dispatched while a test runs, which is the
        // same state a Quit-menu terminate(_:) finds.
        #expect(TerminationReason.current == .application)
    }
}
