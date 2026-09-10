//
//  EffectParameterFormatTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import TingraApp

@Suite("EffectParameterFormat")
struct EffectParameterFormatTests {
    /// A Crop-like inset: a stored fraction declared as percent.
    private let inset = EffectParameter(key: "left", name: "Left", range: 0...0.9, defaultValue: 0, unit: "%")

    /// A Blur-like pixel radius.
    private let radius = EffectParameter(
        key: "radiusPixels", name: "Radius", range: 0...100, defaultValue: 0, unit: "px")

    /// A unitless amount.
    private let amount = EffectParameter(key: "amount", name: "Amount", range: -1...1, defaultValue: 0)

    @Test("a percent parameter displays its stored fraction times a hundred and stores a typed percent back")
    func percentRoundTrip() {
        #expect(EffectParameterFormat.isPercent(inset))
        #expect(EffectParameterFormat.displayValue(0.33, for: inset) == 33)
        #expect(abs(EffectParameterFormat.storedValue(33, for: inset) - 0.33) < 1e-12)
        #expect(EffectParameterFormat.fractionDigits(for: inset) == 0)
    }

    @Test("other units display and store the value as it is, with no fraction digits")
    func unitPassesThrough() {
        #expect(!EffectParameterFormat.isPercent(radius))
        #expect(EffectParameterFormat.displayValue(42, for: radius) == 42)
        #expect(EffectParameterFormat.storedValue(42, for: radius) == 42)
        #expect(EffectParameterFormat.fractionDigits(for: radius) == 0)
    }

    @Test("a unitless parameter shows one fraction digit")
    func unitlessShowsOneDigit() {
        #expect(EffectParameterFormat.fractionDigits(for: amount) == 1)
        #expect(EffectParameterFormat.displayValue(0.25, for: amount) == 0.25)
    }

    @Test("a typed value is clamped to the parameter's declared range")
    func typedValueClamps() {
        // 150 % of a 0…0.9 inset is the top of the range; a negative percent the bottom.
        #expect(EffectParameterFormat.storedValue(150, for: inset) == 0.9)
        #expect(EffectParameterFormat.storedValue(-5, for: inset) == 0)
        #expect(EffectParameterFormat.storedValue(999, for: radius) == 100)
        #expect(EffectParameterFormat.storedValue(-3, for: amount) == -1)
    }
}
