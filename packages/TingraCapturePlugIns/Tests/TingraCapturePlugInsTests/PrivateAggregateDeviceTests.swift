//
//  PrivateAggregateDeviceTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio
import Foundation
import Testing

@testable import TingraCapturePlugIns

/// The two private-aggregate rules, with no audio hardware: the UID rule a
/// document relies on, and the composition rule that must not catch a
/// user's own aggregate.
@Suite("PrivateAggregateDevice")
struct PrivateAggregateDeviceTests {
    @Test("a UID with macOS's private-aggregate prefix matches")
    func prefixedUIDMatches() {
        #expect(PrivateAggregateDevice.matches(uid: "CADefaultDeviceAggregate-52523-0"))
        #expect(PrivateAggregateDevice.matches(uid: "CADefaultDeviceAggregate-1-1"))
    }

    @Test("a real microphone's UID does not match")
    func realDeviceUIDsDoNotMatch() {
        #expect(!PrivateAggregateDevice.matches(uid: "BuiltInMicrophoneDevice"))
        #expect(!PrivateAggregateDevice.matches(uid: "AppleUSBAudioEngine:RØDE:Wireless MICRO:201RXB2532201234:2"))
        #expect(!PrivateAggregateDevice.matches(uid: ""))
    }

    @Test("the prefix must lead the UID, not merely appear in it")
    func prefixMustLead() {
        #expect(!PrivateAggregateDevice.matches(uid: "MyCADefaultDeviceAggregate-1-0"))
        #expect(!PrivateAggregateDevice.matches(uid: "cadefaultdeviceaggregate-1-0"))
    }

    @Test("a composition flagged private as an Int, a Bool, or an NSNumber is private")
    func flaggedCompositionsArePrivate() {
        let key = kAudioAggregateDeviceIsPrivateKey as String
        #expect(PrivateAggregateDevice.isPrivateComposition([key: 1]))
        #expect(PrivateAggregateDevice.isPrivateComposition([key: true]))
        #expect(PrivateAggregateDevice.isPrivateComposition([key: NSNumber(value: 1)]))
    }

    @Test(
        "a composition without the private key, or with it cleared, is public — a user's aggregate stays a microphone")
    func unflaggedCompositionsArePublic() {
        let key = kAudioAggregateDeviceIsPrivateKey as String
        #expect(!PrivateAggregateDevice.isPrivateComposition([:]))
        #expect(!PrivateAggregateDevice.isPrivateComposition([key: 0]))
        #expect(!PrivateAggregateDevice.isPrivateComposition([key: false]))
        #expect(!PrivateAggregateDevice.isPrivateComposition([key: "1"]))
    }

    @Test("a UID no present device carries falls back to the prefix rule")
    func unresolvableUIDFallsBackToPrefix() {
        // Neither UID resolves on any Mac, so the HAL lookup misses for both
        // and only the prefix decides.
        #expect(PrivateAggregateDevice.isPrivate(uid: "CADefaultDeviceAggregate-99999-0"))
        #expect(!PrivateAggregateDevice.isPrivate(uid: "tingra-test-no-such-device"))
    }
}
