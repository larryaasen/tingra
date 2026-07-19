//
//  StripMeterTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraAudio

@testable import Tingra

/// The meter ballistics under explicit timestamps: attack is instant, decay
/// follows real elapsed time at 20 dB per second on the −60…0 dBFS scale.
@Suite("MeterBallistics")
@MainActor
struct StripMeterTests {
    /// A fixed reference instant the tests advance from.
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test("attack is instant: a full-scale reading fills the meter on its first draw")
    func instantAttackFillsTheMeter() {
        let ballistics = MeterBallistics()
        let smoothed = ballistics.smoothed(MeterReading(peak: 1, rms: 1), at: start)
        #expect(smoothed.rms == 1)
        #expect(smoothed.peak == 1)
    }

    @Test("the display decays at 20 dB per second once the signal drops")
    func decayFollowsElapsedTime() {
        let ballistics = MeterBallistics()
        _ = ballistics.smoothed(MeterReading(peak: 1, rms: 1), at: start)
        let smoothed = ballistics.smoothed(.floor, at: start.addingTimeInterval(1))
        // One second after full scale: 20 dB down on a 60 dB scale.
        #expect(abs(smoothed.rms - 2.0 / 3.0) < 0.0001)
        #expect(abs(smoothed.peak - 2.0 / 3.0) < 0.0001)
    }

    @Test("a louder reading overrides the decay immediately")
    func louderReadingOverridesDecay() {
        let ballistics = MeterBallistics()
        _ = ballistics.smoothed(MeterReading(peak: 0.1, rms: 0.1), at: start)
        let smoothed = ballistics.smoothed(MeterReading(peak: 1, rms: 1), at: start.addingTimeInterval(0.5))
        #expect(smoothed.rms == 1)
        #expect(smoothed.peak == 1)
    }

    @Test("silence rests at the floor")
    func silenceRestsAtTheFloor() {
        let ballistics = MeterBallistics()
        let smoothed = ballistics.smoothed(.floor, at: start)
        #expect(smoothed.rms == 0)
        #expect(smoothed.peak == 0)
    }

    @Test("a long decay bottoms out at the floor, never below")
    func decayBottomsOutAtTheFloor() {
        let ballistics = MeterBallistics()
        _ = ballistics.smoothed(MeterReading(peak: 1, rms: 1), at: start)
        // Four seconds decays 80 dB — past the 60 dB scale — and clamps.
        let smoothed = ballistics.smoothed(.floor, at: start.addingTimeInterval(4))
        #expect(smoothed.rms == 0)
        #expect(smoothed.peak == 0)
    }
}
