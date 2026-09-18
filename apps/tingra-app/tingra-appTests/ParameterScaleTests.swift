//
//  ParameterScaleTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraApp

@Suite("Parameter slider scale")
struct ParameterScaleTests {
    /// A level in decibels: linear travel.
    private let level = Parameter(key: "levelDecibels", name: "Level", range: -60...0, defaultValue: -6, unit: "dB")

    /// A frequency across the audible band: logarithmic travel.
    private let frequency = Parameter(
        key: "frequencyHertz", name: "Frequency", range: 20...20_000, defaultValue: 440, unit: "Hz",
        scale: .logarithmic)

    @Test("a linear parameter maps its range evenly onto the travel")
    func linearPositions() {
        #expect(ParameterScale.position(of: -60, for: level) == 0)
        #expect(ParameterScale.position(of: -30, for: level) == 0.5)
        #expect(ParameterScale.position(of: 0, for: level) == 1)
        #expect(ParameterScale.value(at: 0.25, for: level) == -45)
    }

    @Test("a logarithmic parameter puts its geometric middle at half travel")
    func logarithmicPositions() {
        // The geometric middle of 20…20 000 Hz is 632.5 Hz — near the 440 Hz
        // the slider is drawn for, which is the whole point of the scale.
        let middle = sqrt(20 * 20_000.0)
        #expect(abs(ParameterScale.position(of: middle, for: frequency) - 0.5) < 1e-9)
        #expect(abs(ParameterScale.value(at: 0.5, for: frequency) - middle) < 1e-6)
        #expect(ParameterScale.position(of: 20, for: frequency) == 0)
        #expect(abs(ParameterScale.position(of: 20_000, for: frequency) - 1) < 1e-12)
    }

    @Test("position and value invert each other on both scales")
    func roundTrip() {
        for travel in stride(from: 0.0, through: 1.0, by: 0.125) {
            let hertz = ParameterScale.value(at: travel, for: frequency)
            #expect(abs(ParameterScale.position(of: hertz, for: frequency) - travel) < 1e-9)
            let decibels = ParameterScale.value(at: travel, for: level)
            #expect(abs(ParameterScale.position(of: decibels, for: level) - travel) < 1e-9)
        }
    }

    @Test("values and positions outside the range clamp to the travel's ends")
    func clamps() {
        #expect(ParameterScale.position(of: 100_000, for: frequency) == 1)
        #expect(ParameterScale.position(of: 1, for: frequency) == 0)
        #expect(ParameterScale.value(at: 1.5, for: level) == 0)
        #expect(ParameterScale.value(at: -1, for: level) == -60)
    }

    @Test("a logarithmic parameter whose range reaches zero maps linearly instead of producing a NaN")
    func logarithmicWithZeroLowerBoundFallsBackToLinear() {
        let gain = Parameter(key: "gain", name: "Gain", range: 0...2, defaultValue: 1, scale: .logarithmic)
        #expect(ParameterScale.position(of: 1, for: gain) == 0.5)
        #expect(ParameterScale.value(at: 0.75, for: gain) == 1.5)
    }

    @Test("a range with no width maps every value to the start and every position to the bound")
    func degenerateRange() {
        let fixed = Parameter(key: "fixed", name: "Fixed", range: 3...3, defaultValue: 3)
        #expect(ParameterScale.position(of: 3, for: fixed) == 0)
        #expect(ParameterScale.value(at: 0.5, for: fixed) == 3)
    }
}
