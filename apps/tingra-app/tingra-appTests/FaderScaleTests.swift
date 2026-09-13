//
//  FaderScaleTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// The fader scale: a breakpoint table linear in decibels between stops,
/// with silence at the bottom, unity three quarters up a strip's travel and
/// at the top of the monitor's, and gain as the only stored truth.
@Suite("FaderScale")
struct FaderScaleTests {
    /// A tolerance for decibel and position comparisons.
    private let tolerance = 0.0001

    @Test("the bottom of the travel is silence")
    func bottomIsSilence() {
        #expect(FaderScale.strip.gain(forPosition: 0) == 0)
        #expect(FaderScale.strip.position(forGain: 0) == 0)
        #expect(FaderScale.monitor.gain(forPosition: 0) == 0)
    }

    @Test("a strip's fader reads unity three quarters of the way up")
    func stripUnityIsThreeQuartersUp() {
        #expect(abs(FaderScale.strip.unityPosition - 0.75) < tolerance)
        #expect(abs(FaderScale.strip.gain(forPosition: 0.75) - 1) < tolerance)
    }

    @Test("a strip's fader reads +6 dB at the top")
    func stripTopIsPlusSix() {
        let gain = FaderScale.strip.gain(forPosition: 1)
        #expect(abs(FaderScale.decibels(forGain: gain) - 6) < tolerance)
    }

    @Test("every stop of the strip table above the bottom reads its own decibels")
    func stopsReadTheirDecibels() {
        // The bottom stop's position is silence by design; its decibels are
        // what the scale approaches from just above it.
        for stop in FaderScale.strip.stops where stop.position > 0 {
            let gain = FaderScale.strip.gain(forPosition: stop.position)
            #expect(abs(FaderScale.decibels(forGain: gain) - stop.decibels) < tolerance)
        }
    }

    @Test("between stops the scale is linear in decibels")
    func linearInDecibelsBetweenStops() {
        // Halfway between the −20 dB stop (0.40) and the −10 dB stop (0.55).
        let gain = FaderScale.strip.gain(forPosition: 0.475)
        #expect(abs(FaderScale.decibels(forGain: gain) - -15) < tolerance)
    }

    @Test("position and gain round-trip across the travel")
    func positionAndGainRoundTrip() {
        for position in stride(from: 0.05, through: 1, by: 0.05) {
            let gain = FaderScale.strip.gain(forPosition: position)
            #expect(abs(FaderScale.strip.position(forGain: gain) - position) < tolerance)
        }
    }

    @Test("the monitor's fader reads unity at the top and nothing above it")
    func monitorTopIsUnity() {
        #expect(abs(FaderScale.monitor.unityPosition - 1) < tolerance)
        #expect(abs(FaderScale.monitor.gain(forPosition: 1) - 1) < tolerance)
        #expect(FaderScale.monitor.stops.last?.decibels == 0)
        // Stretched from the strip table: −20 dB, at 0.40 of a strip's travel,
        // sits at 0.40 / 0.75 of the monitor's.
        #expect(abs(FaderScale.monitor.position(forGain: FaderScale.gain(forDecibels: -20)) - 0.4 / 0.75) < tolerance)
    }

    @Test("a gain above the top parks the knob at the top")
    func gainAboveTopParksAtTop() {
        #expect(FaderScale.strip.position(forGain: 4) == 1)
        #expect(FaderScale.monitor.position(forGain: 2) == 1)
    }

    @Test("a gain quieter than the bottom stop parks the knob at the stop, not at silence")
    func gainBelowBottomStopParksAtStop() {
        let position = FaderScale.strip.position(forGain: FaderScale.gain(forDecibels: -90))
        #expect(position == 0)
        // And the stop itself is not silence: dragging there yields −72 dB.
        #expect(FaderScale.strip.gain(forPosition: 0.0001) > 0)
    }

    @Test("the readout shows one decimal with an explicit sign, and no sign on zero")
    func readoutFormatting() {
        let positive = FaderScale.readout(forGain: FaderScale.gain(forDecibels: 6))
        #expect(positive == (6.0).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())))
        let negative = FaderScale.readout(forGain: FaderScale.gain(forDecibels: -12.34))
        #expect(negative == (-12.3).formatted(.number.precision(.fractionLength(1))))
        #expect(FaderScale.readout(forGain: 1) == (0.0).formatted(.number.precision(.fractionLength(1))))
    }

    @Test("a gain a hair under unity reads zero, never negative zero")
    func readoutNeverShowsNegativeZero() {
        #expect(FaderScale.readout(forGain: 0.9999) == (0.0).formatted(.number.precision(.fractionLength(1))))
    }

    @Test("the readout is nil at silence")
    func readoutIsNilAtSilence() {
        #expect(FaderScale.readout(forGain: 0) == nil)
        #expect(FaderScale.readout(forGain: -1) == nil)
    }

    @Test("two scales with the same stops are equal, and different stops are not")
    func equality() {
        #expect(FaderScale.strip == FaderScale(stops: FaderScale.strip.stops))
        #expect(FaderScale.strip != FaderScale.monitor)
    }
}
