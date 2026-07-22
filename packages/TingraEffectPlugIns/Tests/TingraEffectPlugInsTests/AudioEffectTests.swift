//
//  AudioEffectTests.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraEffectPlugIns

/// The mix rate the tests process at.
private let sampleRate = 48000.0

/// A constant (DC) block of the given length.
private func dcBlock(_ value: Float, count: Int = 1024) -> [[Float]] {
    [[Float](repeating: value, count: count)]
}

/// A sine block at the given frequency and unity amplitude.
private func sineBlock(frequency: Double, count: Int = 1024) -> [[Float]] {
    [(0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }]
}

/// Runs several warm-up blocks through a filter effect and returns the
/// last block — steady state, past the filter's settling transient.
private func steadyState(
    of effect: inout some AudioEffect,
    block: @autoclosure () -> [[Float]],
    warmUpBlocks: Int = 20
) -> [[Float]] {
    var output: [[Float]] = block()
    for _ in 0..<warmUpBlocks {
        output = block()
        effect.process(&output, sampleRate: sampleRate)
    }
    return output
}

@Suite("Built-in audio effects")
struct AudioEffectTests {
    @Test("gain at unity leaves every sample untouched")
    func gainAtUnityIsIdentity() {
        let effect = GainEffect()
        var block = dcBlock(0.5)
        effect.process(&block, sampleRate: sampleRate)
        #expect(block == dcBlock(0.5))
    }

    @Test("a +6 dB gain doubles the signal, within float tolerance")
    func gainSixDecibelsDoubles() {
        var effect = GainEffect()
        effect.setParameters(["gainDecibels": .double(6.0206)])
        var block = dcBlock(0.25)
        effect.process(&block, sampleRate: sampleRate)
        #expect(abs((block[0].first ?? 0) - 0.5) < 0.001)
    }

    @Test("a gain payload beyond the declared range is clamped, never over-applied")
    func gainClampsToRange() {
        var effect = GainEffect()
        effect.setParameters(["gainDecibels": .double(200)])
        var block = dcBlock(0.001)
        effect.process(&block, sampleRate: sampleRate)
        // +24 dB is the cap: ×10^1.2 ≈ ×15.85, so 0.001 → ~0.0159.
        #expect(abs((block[0].first ?? 0) - 0.001 * Float(pow(10, 1.2))) < 0.001)
    }

    @Test("a gain payload with an integer value applies — the forgiving numeric read")
    func gainAcceptsIntegerPayload() {
        var effect = GainEffect()
        effect.setParameters(["gainDecibels": .int(-6)])
        var block = dcBlock(0.5)
        effect.process(&block, sampleRate: sampleRate)
        #expect(abs((block[0].first ?? 0) - 0.5 * Float(pow(10, -0.3))) < 0.001)
    }

    @Test("the high-pass filter attenuates DC to silence at steady state")
    func highPassRemovesDC() {
        var effect = HighPassEffect()
        let output = steadyState(of: &effect, block: dcBlock(1))
        #expect(abs(output[0].last ?? 1) < 0.001)
    }

    @Test("the high-pass filter passes a tone well above its cutoff at unity")
    func highPassPassesHighTone() {
        var effect = HighPassEffect()
        effect.setParameters(["cutoffHertz": .double(20)])
        // One long phase-continuous block: a per-block restarted sine would
        // put a broadband click at each boundary and muddy the measurement.
        var block = sineBlock(frequency: 1000, count: 48000)
        effect.process(&block, sampleRate: sampleRate)
        let peak = block[0].suffix(1024).map(abs).max() ?? 0
        #expect(abs(peak - 1) < 0.05)
    }

    @Test("the low-pass filter passes DC at unity at steady state")
    func lowPassPassesDC() {
        var effect = LowPassEffect()
        let output = steadyState(of: &effect, block: dcBlock(0.5))
        #expect(abs((output[0].last ?? 0) - 0.5) < 0.005)
    }

    @Test("the low-pass filter attenuates a tone well above its cutoff")
    func lowPassAttenuatesHighTone() {
        var effect = LowPassEffect()
        effect.setParameters(["cutoffHertz": .double(200)])
        // One long phase-continuous block, as in the high-pass passband test.
        var block = sineBlock(frequency: 8000, count: 48000)
        effect.process(&block, sampleRate: sampleRate)
        let peak = block[0].suffix(1024).map(abs).max() ?? 1
        // A second-order filter is 12 dB/octave; 8 kHz sits over five
        // octaves past 200 Hz, so the tone should be far below −40 dB.
        #expect(peak < 0.01)
    }

    @Test("a filter keeps separate memory per channel — a stereo block filters each channel independently")
    func filterKeepsPerChannelMemory() {
        var effect = HighPassEffect()
        var output: [[Float]] = []
        for _ in 0..<20 {
            var block = [
                [Float](repeating: 1, count: 1024),
                [Float](repeating: 0, count: 1024),
            ]
            effect.process(&block, sampleRate: sampleRate)
            output = block
        }
        // The DC channel settles to silence; the silent channel stays
        // silent — no cross-channel bleed through shared memory.
        #expect(abs(output[0].last ?? 1) < 0.001)
        #expect(output[1].allSatisfy { $0 == 0 })
    }

    @Test("a cutoff payload beyond the declared range is clamped")
    func filterClampsCutoffToRange() {
        var effect = HighPassEffect()
        // Clamped to the 1 kHz cap: an 8 kHz tone still passes near unity.
        effect.setParameters(["cutoffHertz": .double(1_000_000)])
        var block = sineBlock(frequency: 8000, count: 48000)
        effect.process(&block, sampleRate: sampleRate)
        let peak = block[0].suffix(1024).map(abs).max() ?? 0
        #expect(peak > 0.9)
    }

    @Test("providers build their effect at the payload's settings")
    func providersApplyPayloadAtCreation() {
        let effect = GainEffectProvider().makeEffect(parameters: ["gainDecibels": .double(-6.0206)])
        var mutable = effect
        var block = dcBlock(0.5)
        mutable.process(&block, sampleRate: sampleRate)
        #expect(abs((block[0].first ?? 0) - 0.25) < 0.001)
    }
}
