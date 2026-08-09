//
//  StatusBarItemTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import Testing

@testable import TingraApp

@Suite("StatusBarItem")
@MainActor
struct StatusBarItemTests {
    @Test("a live stream reads on")
    func liveStreamReadsOn() {
        #expect(StatusBarItem.streaming(.live).light == .on)
    }

    @Test("a stream that is connecting or reconnecting reads pending")
    func inFlightStreamReadsPending() {
        #expect(StatusBarItem.streaming(.starting).light == .pending)
        #expect(StatusBarItem.streaming(.reconnecting(attempt: 2, maxAttempts: 5)).light == .pending)
    }

    @Test("a stream that never started and one that ended cleanly read the same")
    func idleAndStoppedStreamsReadTheSame() {
        #expect(StatusBarItem.streaming(.idle) == StatusBarItem.streaming(.stopped))
        #expect(StatusBarItem.streaming(.idle).light == .off)
    }

    @Test("a stream that ended on a failure reads as a fault")
    func streamErrorReadsAsAFault() {
        #expect(StatusBarItem.streaming(.error("unreachable host")).light == .fault)
    }

    @Test("a rolling recording reads on")
    func rollingRecordingReadsOn() {
        #expect(StatusBarItem.recording(.recording).light == .on)
    }

    @Test("a recording still being closed reads pending, never off")
    func finalizingRecordingReadsPending() {
        // The distinction that matters most on this bar: a file that is still
        // being closed is not yet playable, so it must not read as "nothing
        // is happening".
        #expect(StatusBarItem.recording(.finalizing).light == .pending)
        #expect(StatusBarItem.recording(.starting).light == .pending)
    }

    @Test("no recording reads off")
    func idleRecordingReadsOff() {
        #expect(StatusBarItem.recording(.idle).light == .off)
    }

    @Test("a recording that ended on a failure reads as a fault")
    func recordingErrorReadsAsAFault() {
        #expect(StatusBarItem.recording(.error("the volume is full")).light == .fault)
    }

    @Test("a fault draws the warning symbol on both readings")
    func faultsDrawTheWarningSymbol() {
        #expect(StatusBarItem.streaming(.error("x")).systemImage == "exclamationmark.triangle.fill")
        #expect(StatusBarItem.recording(.error("x")).systemImage == "exclamationmark.triangle.fill")
    }

    @Test("a stream that is not running draws the crossed-out antenna")
    func offStreamDrawsTheCrossedOutAntenna() {
        #expect(StatusBarItem.streaming(.idle).systemImage.hasSuffix(".slash"))
        #expect(StatusBarItem.streaming(.live).systemImage.hasSuffix(".slash") == false)
    }

    @Test("a rolling recording fills its record dot")
    func rollingRecordingFillsItsDot() {
        #expect(StatusBarItem.recording(.recording).systemImage == "record.circle.fill")
        #expect(StatusBarItem.recording(.idle).systemImage == "record.circle")
    }

    @Test("the two readings of one status are equal, and two different ones are not")
    func equalityHoldsBothWays() {
        #expect(StatusBarItem.recording(.recording) == StatusBarItem.recording(.recording))
        #expect(StatusBarItem.recording(.recording) != StatusBarItem.recording(.idle))
    }

    @Test("each lamp state carries its own tint, with on and fault sharing red")
    func lampTints() {
        #expect(StatusBarItem.Light.off.tint == .secondary)
        #expect(StatusBarItem.Light.pending.tint == .orange)
        #expect(StatusBarItem.Light.on.tint == .red)
        #expect(StatusBarItem.Light.fault.tint == .red)
    }

    @Test("only the states an operator must not miss are emphasized")
    func onlyUrgentStatesAreProminent() {
        #expect(StatusBarItem.Light.on.isProminent)
        #expect(StatusBarItem.Light.fault.isProminent)
        #expect(StatusBarItem.Light.off.isProminent == false)
        #expect(StatusBarItem.Light.pending.isProminent == false)
    }
}
