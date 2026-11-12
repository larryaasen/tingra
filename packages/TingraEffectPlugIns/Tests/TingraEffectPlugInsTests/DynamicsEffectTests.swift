//
//  DynamicsEffectTests.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraEffectPlugIns

/// The mix rate the tests process at.
private let sampleRate = 48000.0

/// The mixer's block length at the default format — the block size the
/// tests use unless a test is about block boundaries.
private let mixBlock = 1024

/// A level in decibels as a linear sample value.
private func linear(_ decibels: Double) -> Float {
    Float(pow(10, decibels / 20))
}

/// A linear sample value's level in decibels.
private func decibels(_ linear: Float) -> Double {
    20 * log10(Double(linear))
}

/// The whole frames in a duration at a sample rate.
private func frames(milliseconds: Double, at rate: Double = sampleRate) -> Int {
    Int((milliseconds / 1000 * rate).rounded())
}

/// A constant signal of the given length.
private func constant(_ value: Float, milliseconds: Double) -> [Float] {
    [Float](repeating: value, count: frames(milliseconds: milliseconds))
}

/// A phase-continuous sine of the given amplitude and length.
private func sine(frequency: Double, amplitude: Float, milliseconds: Double) -> [Float] {
    (0..<frames(milliseconds: milliseconds)).map {
        amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate))
    }
}

/// Deterministic noise in `-amplitude...amplitude` from a linear
/// congruential generator, so a test's signal is the same on every run.
private func noise(amplitude: Float, count: Int, seed: UInt32) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 1_664_525 &+ 1_013_904_223
        return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
    }
}

/// Runs a signal through an effect the way the mixer does — block after
/// block, the effect's state carried between them — and returns the
/// whole output. The block sizes are cycled through, so a test can cut
/// the signal at uneven places.
private func run(
    _ effect: inout some AudioEffect,
    _ signal: [[Float]],
    blockSizes: [Int] = [mixBlock],
    at rate: Double = sampleRate
) -> [[Float]] {
    var output = [[Float]](repeating: [], count: signal.count)
    let total = signal.map(\.count).min() ?? 0
    var start = 0
    var turn = 0
    while start < total {
        let count = min(blockSizes[turn % blockSizes.count], total - start)
        var block = signal.map { Array($0[start..<start + count]) }
        effect.process(&block, sampleRate: rate)
        for c in output.indices {
            output[c].append(contentsOf: block[c])
        }
        start += count
        turn += 1
    }
    return output
}

/// Block sizes that cut a signal at uneven places: single samples, sizes
/// under and over the shared walk's 256-frame chunk, and the mix block.
private let unevenBlocks = [1, 7, 255, 256, 257, 1024, 3, 700]

@Suite("LinkedDynamics")
struct LinkedDynamicsTests {
    @Test("each frame's level is the loudest channel's magnitude, and one gain scales every channel")
    func levelIsLoudestChannel() {
        var block: [[Float]] = [[0.1, -0.8, 0.0], [-0.5, 0.2, 0.0]]
        var levels: [Float] = []
        LinkedDynamics.apply(to: &block) { level in
            levels.append(level)
            return 0.5
        }
        #expect(levels == [0.5, 0.8, 0.0])
        #expect(block == [[0.05, -0.4, 0.0], [-0.25, 0.1, 0.0]])
    }

    @Test("frames are visited once each, in order, across the walk's chunks")
    func framesVisitedInOrder() {
        let count = LinkedDynamics.chunkFrames * 3 + 17
        var block = [(0..<count).map { Float($0) }]
        var levels: [Float] = []
        LinkedDynamics.apply(to: &block) { level in
            levels.append(level)
            return 1
        }
        #expect(levels == (0..<count).map { Float($0) })
    }

    @Test("a sample that is not finite never raises the level")
    func nonFiniteSamplesAreNotLevels() {
        var block: [[Float]] = [[.infinity, .nan, -.infinity], [0.25, 0.5, 0.75]]
        var levels: [Float] = []
        LinkedDynamics.apply(to: &block) { level in
            levels.append(level)
            return 1
        }
        #expect(levels == [0.25, 0.5, 0.75])
    }

    @Test("channels of unequal length are processed over the frames they share, and keep their shape")
    func unequalChannelsKeepShape() {
        var block: [[Float]] = [[1, 1, 1], [1]]
        LinkedDynamics.apply(to: &block) { _ in 0.5 }
        #expect(block == [[0.5, 1, 1], [0.5]])
    }

    @Test("no channels and empty channels are left alone")
    func emptyBlocksAreLeftAlone() {
        var none: [[Float]] = []
        var empty: [[Float]] = [[], []]
        var calls = 0
        LinkedDynamics.apply(to: &none) { _ in
            calls += 1
            return 0
        }
        LinkedDynamics.apply(to: &empty) { _ in
            calls += 1
            return 0
        }
        #expect(none.isEmpty)
        #expect(empty == [[], []])
        #expect(calls == 0)
    }

    @Test("a time constant leaves 1/e of the distance after its own length, and none when it is zero")
    func smoothingCoefficientIsATimeConstant() {
        let coefficient = LinkedDynamics.smoothingCoefficient(milliseconds: 10, sampleRate: sampleRate)
        #expect(abs(pow(Double(coefficient), 480) - exp(-1)) < 0.001)
        #expect(LinkedDynamics.smoothingCoefficient(milliseconds: 0, sampleRate: sampleRate) == 0)
        #expect(LinkedDynamics.smoothingCoefficient(milliseconds: 10, sampleRate: 0) == 0)
        #expect(LinkedDynamics.smoothingCoefficient(milliseconds: -5, sampleRate: sampleRate) == 0)
    }
}

@Suite("Limiter effect")
struct LimiterEffectTests {
    @Test("a signal under the ceiling passes untouched, sample for sample")
    func underCeilingIsIdentity() {
        var effect = LimiterEffect()
        let signal = [sine(frequency: 440, amplitude: 0.5, milliseconds: 500)]
        #expect(run(&effect, signal) == signal)
    }

    @Test("a steady signal over the ceiling is held at the ceiling from its first sample")
    func steadySignalSitsAtCeiling() {
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .double(-6)])
        let output = run(&effect, [constant(2, milliseconds: 200)])
        let ceiling = linear(-6)
        #expect(output[0].allSatisfy { abs($0 - ceiling) < 1e-5 })
    }

    @Test(
        "no sample ever leaves over the ceiling, whatever the signal and wherever the blocks fall",
        arguments: [-24.0, -6.0, -1.0, 0.0])
    func ceilingIsNeverExceeded(ceilingDecibels: Double) {
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .double(ceilingDecibels), "releaseMilliseconds": .double(10)])
        let count = frames(milliseconds: 2000)
        let signal = [
            noise(amplitude: 8, count: count, seed: 1),
            zip(noise(amplitude: 3, count: count, seed: 2), sine(frequency: 61, amplitude: 4, milliseconds: 2000))
                .map { $0 + $1 },
        ]
        let output = run(&effect, signal, blockSizes: unevenBlocks)
        let ceiling = linear(ceilingDecibels)
        let peak = output.flatMap { $0 }.map(abs).max() ?? 0
        #expect(peak <= ceiling)
        // It limits rather than mutes: the loud signal sits at the ceiling.
        #expect(peak > ceiling * 0.99)
    }

    @Test("a single spike out of silence is already within the ceiling — there is no attack time")
    func spikeIsCaughtOnItsOwnSample() {
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .double(-6)])
        var signal = constant(0, milliseconds: 20)
        signal[500] = 5
        signal[501] = -7
        let output = run(&effect, [signal])
        #expect(abs(output[0][500] - linear(-6)) < 1e-5)
        #expect(abs(output[0][501] + linear(-6)) < 1e-5)
    }

    @Test("the gain recovers over the release time constant, across block boundaries, back to exactly unity")
    func releaseRecoversOverItsTimeConstant() {
        var effect = LimiterEffect()
        // A ceiling of 0.5 and a level of 2: the gain is held at 0.25.
        effect.setParameters(["ceilingDecibels": .double(decibels(0.5)), "releaseMilliseconds": .double(100)])
        let loud = constant(2, milliseconds: 100)
        let quiet = constant(0.1, milliseconds: 3000)
        let output = run(&effect, [loud + quiet], blockSizes: unevenBlocks)[0]
        let afterRelease = output[loud.count + frames(milliseconds: 100) - 1] / 0.1
        // One time constant covers 1 − 1/e of the way from 0.25 to 1.
        let expected = 1 - 0.75 * exp(-1.0)
        #expect(abs(Double(afterRelease) - expected) < 0.005)
        #expect(output[loud.count] < 0.1 * 0.26)
        #expect(output.last == 0.1)
    }

    @Test("the longest release still arrives at exactly unity rather than stalling just short of it")
    func longestReleaseSettles() {
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .double(decibels(0.5)), "releaseMilliseconds": .double(1000)])
        let signal = constant(2, milliseconds: 10) + constant(0.1, milliseconds: 16000)
        #expect(run(&effect, [signal])[0].last == 0.1)
    }

    @Test("a shorter release recovers sooner")
    func shorterReleaseRecoversSooner() {
        let signal = [constant(2, milliseconds: 50) + constant(0.1, milliseconds: 50)]
        var slow = LimiterEffect()
        slow.setParameters(["ceilingDecibels": .double(-6), "releaseMilliseconds": .double(1000)])
        var fast = LimiterEffect()
        fast.setParameters(["ceilingDecibels": .double(-6), "releaseMilliseconds": .double(10)])
        let slowLast = run(&slow, signal)[0].last ?? 0
        let fastLast = run(&fast, signal)[0].last ?? 0
        #expect(fastLast > slowLast)
        #expect(abs(fastLast - 0.1) < 0.001)
    }

    @Test("the output is the same however the signal is cut into blocks")
    func blockBoundariesDoNotChangeTheOutput() {
        let signal = [
            sine(frequency: 220, amplitude: 3, milliseconds: 300) + constant(0.05, milliseconds: 300),
            noise(amplitude: 2, count: frames(milliseconds: 600), seed: 7),
        ]
        var whole = LimiterEffect()
        var cut = LimiterEffect()
        let expected = run(&whole, signal, blockSizes: [signal[0].count])
        #expect(run(&cut, signal, blockSizes: unevenBlocks) == expected)
    }

    @Test("one gain serves both channels, so a loud left turns the right down by the same amount")
    func stereoIsLinked() {
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .double(decibels(0.5))])
        let output = run(&effect, [constant(2, milliseconds: 50), constant(0.2, milliseconds: 50)])
        #expect(output[0].allSatisfy { abs($0 - 0.5) < 1e-5 })
        #expect(output[1].allSatisfy { abs($0 - 0.05) < 1e-5 })
    }

    @Test("samples that are not finite leave finite and within the ceiling, and the limiter carries on")
    func nonFiniteSamplesAreContained() {
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .double(-6), "releaseMilliseconds": .double(10)])
        let ceiling = linear(-6)
        var block: [[Float]] = [[.nan, .infinity, -.infinity, 0.3, 4, -4]]
        effect.process(&block, sampleRate: sampleRate)
        #expect(block[0].allSatisfy { $0.isFinite && abs($0) <= ceiling })
        #expect(block[0][0] == 0)
        #expect(block[0][1] == ceiling)
        #expect(block[0][2] == -ceiling)
        // The gain was never poisoned: a quiet signal comes back whole.
        let later = run(&effect, [constant(0.1, milliseconds: 1000)])[0]
        #expect(later.last == 0.1)
    }

    @Test("a ceiling beyond the declared range is clamped to it")
    func ceilingClampsToRange() {
        var high = LimiterEffect()
        high.setParameters(["ceilingDecibels": .double(20)])
        #expect(run(&high, [constant(2, milliseconds: 10)])[0].allSatisfy { abs($0 - 1) < 1e-5 })

        var low = LimiterEffect()
        low.setParameters(["ceilingDecibels": .double(-100)])
        #expect(run(&low, [constant(2, milliseconds: 10)])[0].allSatisfy { abs($0 - linear(-24)) < 1e-5 })
    }

    @Test("a release beyond the declared range is clamped to it")
    func releaseClampsToRange() {
        // Clamped to 10 ms, so one 10 ms time constant covers 1 − 1/e.
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .double(decibels(0.5)), "releaseMilliseconds": .double(0.001)])
        let loud = constant(2, milliseconds: 10)
        let output = run(&effect, [loud + constant(0.1, milliseconds: 100)])[0]
        let gain = Double(output[loud.count + frames(milliseconds: 10) - 1] / 0.1)
        #expect(abs(gain - (1 - 0.75 * exp(-1.0))) < 0.005)
    }

    @Test("a payload keeps the settings it omits, ignores unknown keys, and takes an integer")
    func payloadIsForgiving() {
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .int(-6)])
        effect.setParameters(["releaseMilliseconds": .double(50), "somethingNewer": .string("x")])
        effect.setParameters(["ceilingDecibels": .string("loud")])
        #expect(run(&effect, [constant(2, milliseconds: 10)])[0].allSatisfy { abs($0 - linear(-6)) < 1e-5 })
    }

    @Test("the default ceiling is 1 dB under full scale")
    func defaultCeiling() {
        let effect = LimiterEffectProvider().makeEffect(parameters: [:])
        var mutable = effect
        var block: [[Float]] = [[4, -4]]
        mutable.process(&block, sampleRate: sampleRate)
        #expect(abs(block[0][0] - linear(-1)) < 1e-5)
        #expect(abs(block[0][1] + linear(-1)) < 1e-5)
    }

    @Test("the provider builds the limiter at the payload's settings")
    func providerAppliesPayload() {
        var effect = LimiterEffectProvider().makeEffect(parameters: ["ceilingDecibels": .double(-12)])
        var block: [[Float]] = [[4]]
        effect.process(&block, sampleRate: sampleRate)
        #expect(abs(block[0][0] - linear(-12)) < 1e-5)
    }

    @Test("silence stays silence, and empty or uneven blocks keep their shape under the ceiling")
    func edgeShapes() {
        var effect = LimiterEffect()
        effect.setParameters(["ceilingDecibels": .double(-6)])
        #expect(run(&effect, [constant(0, milliseconds: 50)])[0].allSatisfy { $0 == 0 })

        var none: [[Float]] = []
        effect.process(&none, sampleRate: sampleRate)
        #expect(none.isEmpty)

        var empty: [[Float]] = [[]]
        effect.process(&empty, sampleRate: sampleRate)
        #expect(empty == [[]])

        // The frames only one channel has are still clamped.
        var uneven: [[Float]] = [[2, 2, 2], [2]]
        effect.process(&uneven, sampleRate: sampleRate)
        #expect(uneven.map(\.count) == [3, 1])
        #expect(uneven.flatMap { $0 }.allSatisfy { abs($0) <= linear(-6) })
    }

    @Test("a sample rate of zero still holds the ceiling")
    func zeroSampleRateStillLimits() {
        var effect = LimiterEffect()
        var block: [[Float]] = [[4, 0.1, -9]]
        effect.process(&block, sampleRate: 0)
        #expect(block[0].allSatisfy { abs($0) <= linear(-1) })
        // With no rate there is no release time: the gain is back at once.
        #expect(block[0][1] == 0.1)
    }
}

@Suite("Compressor effect")
struct CompressorEffectTests {
    /// A compressor with a hard knee, so a steady level's reduction is
    /// the plain ratio arithmetic.
    private func hardKnee(threshold: Double, ratio: Double) -> CompressorEffect {
        var effect = CompressorEffect()
        effect.setParameters([
            "thresholdDecibels": .double(threshold),
            "ratio": .double(ratio),
            "kneeDecibels": .double(0),
        ])
        return effect
    }

    @Test("a signal under the threshold and its knee passes untouched, sample for sample")
    func underThresholdIsIdentity() {
        var effect = CompressorEffect()
        let signal = [sine(frequency: 440, amplitude: linear(-30), milliseconds: 500)]
        #expect(run(&effect, signal) == signal)
    }

    @Test(
        "a steady level settles on threshold + (level − threshold) / ratio",
        arguments: [
            (0.5, -18.0, 4.0),
            (1.0, -20.0, 2.0),
            (0.25, -30.0, 10.0),
            (0.9, -6.0, 20.0),
            (2.0, -12.0, 3.0),
        ])
    func steadyStateFollowsTheRatio(level: Double, threshold: Double, ratio: Double) {
        var effect = hardKnee(threshold: threshold, ratio: ratio)
        let output = run(&effect, [constant(Float(level), milliseconds: 1500)])[0]
        let levelDecibels = 20 * log10(level)
        let expectedDecibels = threshold + (levelDecibels - threshold) / ratio
        #expect(abs(decibels(output.last ?? 0) - expectedDecibels) < 0.01)
    }

    @Test("a steady signal of either sign is compressed alike — the level is the magnitude")
    func negativeSignalsCompressAlike() {
        var positive = hardKnee(threshold: -18, ratio: 4)
        var negative = hardKnee(threshold: -18, ratio: 4)
        let up = run(&positive, [constant(0.5, milliseconds: 500)])[0]
        let down = run(&negative, [constant(-0.5, milliseconds: 500)])[0]
        #expect(up == down.map { -$0 })
    }

    @Test("the knee eases compression in: none under it, the full ratio over it, a quadratic between")
    func softKneeCurve() {
        var effect = CompressorEffect()
        effect.setParameters([
            "thresholdDecibels": .double(-18), "ratio": .double(4), "kneeDecibels": .double(6),
        ])
        #expect(effect.reduction(atLevel: -40) == 0)
        #expect(effect.reduction(atLevel: -21) == 0)
        // At the threshold: (1 − 1/4) × 3² / (2 × 6).
        #expect(abs(effect.reduction(atLevel: -18) - 0.5625) < 1e-5)
        // At the top of the knee the quadratic meets the straight line.
        #expect(abs(effect.reduction(atLevel: -15) - 0.75 * 3) < 1e-5)
        #expect(abs(effect.reduction(atLevel: -14.999) - 0.75 * 3.001) < 1e-4)
        #expect(abs(effect.reduction(atLevel: 0) - 0.75 * 18) < 1e-5)

        // And the processed signal settles on the curve.
        let output = run(&effect, [constant(linear(-18), milliseconds: 1500)])[0]
        #expect(abs(decibels(output.last ?? 0) - (-18 - 0.5625)) < 0.01)
    }

    @Test("a ratio of 1 changes nothing")
    func unityRatioIsIdentity() {
        var effect = hardKnee(threshold: -40, ratio: 1)
        let signal = [sine(frequency: 300, amplitude: 0.9, milliseconds: 300)]
        #expect(run(&effect, signal) == signal)
    }

    @Test("makeup gain raises the whole signal, compressed or not")
    func makeupGainApplies() {
        var effect = hardKnee(threshold: -18, ratio: 4)
        effect.setParameters(["makeupDecibels": .double(6)])
        let quiet = run(&effect, [constant(linear(-40), milliseconds: 100)])[0]
        #expect(abs(decibels(quiet.last ?? 0) - (-40 + 6)) < 0.01)

        let loud = run(&effect, [constant(0.5, milliseconds: 1500)])[0]
        let expected = -18 + (20 * log10(0.5) + 18) / 4 + 6
        #expect(abs(decibels(loud.last ?? 0) - expected) < 0.01)
    }

    @Test("the reduction arrives over the attack time constant, across block boundaries")
    func attackArrivesOverItsTimeConstant() {
        var effect = hardKnee(threshold: -18, ratio: 4)
        effect.setParameters(["attackMilliseconds": .double(10)])
        let output = run(&effect, [constant(0.5, milliseconds: 100)], blockSizes: unevenBlocks)[0]
        let full = 0.75 * (20 * log10(0.5) + 18)
        // The first sample is all but untouched; one time constant in,
        // the reduction is 1 − 1/e of the way there.
        #expect(abs(decibels(output[0]) - 20 * log10(0.5)) < 0.05)
        let reached = 20 * log10(0.5) - decibels(output[frames(milliseconds: 10) - 1])
        #expect(abs(reached - full * (1 - exp(-1.0))) < 0.02)
    }

    @Test("the reduction lets go over the release time constant, back to exactly none")
    func releaseLetsGoOverItsTimeConstant() {
        var effect = hardKnee(threshold: -18, ratio: 4)
        effect.setParameters(["releaseMilliseconds": .double(150)])
        let loud = constant(0.5, milliseconds: 1500)
        let quietLevel = linear(-40)
        let quiet = constant(quietLevel, milliseconds: 4000)
        let output = run(&effect, [loud + quiet], blockSizes: unevenBlocks)[0]
        let full = 0.75 * (20 * log10(0.5) + 18)
        let remaining = -40 - decibels(output[loud.count + frames(milliseconds: 150) - 1])
        #expect(abs(remaining - full * exp(-1.0)) < 0.02)
        #expect(output.last == quietLevel)
    }

    @Test("the time constants follow the sample rate")
    func timeConstantsFollowSampleRate() {
        var effect = hardKnee(threshold: -18, ratio: 4)
        let rate = 44100.0
        let signal = [[Float](repeating: 0.5, count: 4410)]
        let output = run(&effect, signal, at: rate)[0]
        let full = 0.75 * (20 * log10(0.5) + 18)
        // The default 10 ms attack is 441 frames at this rate.
        let reached = 20 * log10(0.5) - decibels(output[frames(milliseconds: 10, at: rate) - 1])
        #expect(abs(reached - full * (1 - exp(-1.0))) < 0.02)

        // The same instance, moved to another rate, recomputes.
        var fresh = hardKnee(threshold: -18, ratio: 4)
        var warm: [[Float]] = [[0]]
        fresh.process(&warm, sampleRate: rate)
        let moved = run(&fresh, [constant(0.5, milliseconds: 100)])[0]
        let movedReached = 20 * log10(0.5) - decibels(moved[frames(milliseconds: 10) - 1])
        #expect(abs(movedReached - full * (1 - exp(-1.0))) < 0.02)
    }

    @Test("the output is the same however the signal is cut into blocks")
    func blockBoundariesDoNotChangeTheOutput() {
        let signal = [
            sine(frequency: 180, amplitude: 0.9, milliseconds: 300) + constant(0.01, milliseconds: 300),
            noise(amplitude: 0.6, count: frames(milliseconds: 600), seed: 11),
        ]
        var whole = CompressorEffect()
        var cut = CompressorEffect()
        let expected = run(&whole, signal, blockSizes: [signal[0].count])
        #expect(run(&cut, signal, blockSizes: unevenBlocks) == expected)
    }

    @Test("one gain serves both channels, so a loud left turns a quiet right down by the same amount")
    func stereoIsLinked() {
        var effect = hardKnee(threshold: -18, ratio: 4)
        let output = run(&effect, [constant(0.5, milliseconds: 1500), constant(0.005, milliseconds: 1500)])
        let leftGain = (output[0].last ?? 0) / 0.5
        let rightGain = (output[1].last ?? 0) / 0.005
        #expect(abs(leftGain - rightGain) < 1e-5)
        #expect(leftGain < 0.5)
    }

    @Test("settings beyond their declared ranges are clamped")
    func settingsClampToRange() {
        // The ratio stops at 20 and the threshold at −60 dB.
        var effect = CompressorEffect()
        effect.setParameters([
            "thresholdDecibels": .double(-500), "ratio": .double(1_000_000), "kneeDecibels": .double(-3),
            "makeupDecibels": .double(-40), "attackMilliseconds": .double(0),
        ])
        let output = run(&effect, [constant(1, milliseconds: 1500)])[0]
        // 0 dB in, 60 dB over: out at −60 + 60 / 20, no makeup (clamped to 0).
        #expect(abs(decibels(output.last ?? 0) - (-60 + 3)) < 0.01)
        // The attack stops at 1 ms: one time constant is 48 frames.
        let reached = -decibels(output[frames(milliseconds: 1) - 1])
        #expect(abs(reached - 57 * (1 - exp(-1.0))) < 0.3)

        var loudMakeup = CompressorEffect()
        loudMakeup.setParameters(["makeupDecibels": .double(400)])
        let made = run(&loudMakeup, [constant(linear(-60), milliseconds: 50)])[0]
        #expect(abs(decibels(made.last ?? 0) - (-60 + 24)) < 0.01)
    }

    @Test("a payload keeps the settings it omits, ignores unknown keys, and takes an integer")
    func payloadIsForgiving() {
        var effect = CompressorEffect()
        effect.setParameters(["thresholdDecibels": .int(-18), "ratio": .int(4), "kneeDecibels": .int(0)])
        effect.setParameters(["releaseMilliseconds": .double(300), "somethingNewer": .bool(true)])
        effect.setParameters(["ratio": .string("lots")])
        let output = run(&effect, [constant(0.5, milliseconds: 1500)])[0]
        #expect(abs(decibels(output.last ?? 0) - (-18 + (20 * log10(0.5) + 18) / 4)) < 0.01)
    }

    @Test("the provider builds the compressor at the payload's settings, and at the defaults without one")
    func providerAppliesPayload() {
        var configured = CompressorEffectProvider().makeEffect(parameters: [
            "thresholdDecibels": .double(-20), "ratio": .double(2), "kneeDecibels": .double(0),
        ])
        let output = run(&configured, [constant(1, milliseconds: 1500)])[0]
        #expect(abs(decibels(output.last ?? 0) - (-10)) < 0.01)

        // Defaults: −18 dB, 3:1, a 6 dB knee, no makeup. 0 dB is over the knee.
        var fresh = CompressorEffectProvider().makeEffect(parameters: [:])
        let defaults = run(&fresh, [constant(1, milliseconds: 1500)])[0]
        #expect(abs(decibels(defaults.last ?? 0) - (-18 + 18.0 / 3)) < 0.01)
    }

    @Test("a sample that is not finite never poisons the envelope")
    func nonFiniteSamplesDoNotPoison() {
        var effect = hardKnee(threshold: -18, ratio: 4)
        var bad: [[Float]] = [[.infinity, .nan, -.infinity]]
        effect.process(&bad, sampleRate: sampleRate)
        let signal = [sine(frequency: 440, amplitude: linear(-30), milliseconds: 100)]
        #expect(run(&effect, signal) == signal)
    }

    @Test("silence stays silence, and empty or uneven blocks keep their shape")
    func edgeShapes() {
        var effect = CompressorEffect()
        #expect(run(&effect, [constant(0, milliseconds: 50)])[0].allSatisfy { $0 == 0 })

        var none: [[Float]] = []
        effect.process(&none, sampleRate: sampleRate)
        #expect(none.isEmpty)

        var empty: [[Float]] = [[], []]
        effect.process(&empty, sampleRate: sampleRate)
        #expect(empty == [[], []])

        var uneven: [[Float]] = [[0.5, 0.5, 0.5], [0.5]]
        effect.process(&uneven, sampleRate: sampleRate)
        #expect(uneven.map(\.count) == [3, 1])
    }

    @Test("a sample rate of zero still compresses, following the level at once")
    func zeroSampleRateStillCompresses() {
        var effect = hardKnee(threshold: -18, ratio: 4)
        var block: [[Float]] = [[0.5, 0.5]]
        effect.process(&block, sampleRate: 0)
        let expected = -18 + (20 * log10(0.5) + 18) / 4
        #expect(abs(decibels(block[0][0]) - expected) < 0.01)
    }
}

@Suite("Gate effect")
struct GateEffectTests {
    /// A gate with a −40 dB threshold — it opens at 0.01 and closes under
    /// 0.00708 — and the given times.
    private func gate(hold: Double = 100, attack: Double = 2, release: Double = 50) -> GateEffect {
        var effect = GateEffect()
        effect.setParameters([
            "thresholdDecibels": .double(-40),
            "holdMilliseconds": .double(hold),
            "attackMilliseconds": .double(attack),
            "releaseMilliseconds": .double(release),
        ])
        return effect
    }

    @Test("a signal under the threshold is silenced")
    func underThresholdIsSilenced() {
        var effect = GateEffect()
        let output = run(&effect, [sine(frequency: 440, amplitude: linear(-60), milliseconds: 500)])
        #expect(output[0].allSatisfy { $0 == 0 })
    }

    @Test("a signal over the threshold opens the gate, and an open gate passes it untouched")
    func overThresholdPassesUntouched() {
        var effect = GateEffect()
        let signal = [sine(frequency: 440, amplitude: 0.5, milliseconds: 1000)]
        let output = run(&effect, signal)
        let settled = frames(milliseconds: 500)
        #expect(Array(output[0][settled...]) == Array(signal[0][settled...]))
    }

    @Test("the gate opens over the attack time constant, across block boundaries")
    func attackOpensOverItsTimeConstant() {
        var effect = gate(attack: 10)
        let output = run(&effect, [constant(0.1, milliseconds: 200)], blockSizes: unevenBlocks)[0]
        // It starts closed, so the first sample is all but silent.
        #expect(output[0] < 0.1 * 0.01)
        let gain = Double(output[frames(milliseconds: 10) - 1] / 0.1)
        #expect(abs(gain - (1 - exp(-1.0))) < 0.005)
        #expect(output.last == 0.1)
    }

    @Test("a signal between the closing and opening levels never opens a closed gate")
    func hysteresisBandDoesNotOpen() {
        var effect = gate()
        // −41.4 dB: under the −40 dB threshold, over the −43 dB closing level.
        let output = run(&effect, [constant(0.0085, milliseconds: 1000)])
        #expect(output[0].allSatisfy { $0 == 0 })
    }

    @Test("a signal between the closing and opening levels keeps an open gate open")
    func hysteresisBandHoldsOpen() {
        var effect = gate(hold: 0)
        let opening = constant(0.1, milliseconds: 500)
        let hovering = constant(0.0085, milliseconds: 3000)
        let output = run(&effect, [opening + hovering])[0]
        #expect(output.last == 0.0085)
        #expect(output[opening.count...].allSatisfy { $0 == 0.0085 })
    }

    @Test("the gate holds open for the hold time after the signal drops, then closes to silence")
    func holdThenClose() {
        var effect = gate(hold: 100, release: 50)
        let opening = constant(0.1, milliseconds: 500)
        let quiet = constant(0.001, milliseconds: 2500)
        let output = run(&effect, [opening + quiet], blockSizes: unevenBlocks)[0]
        // The detector's envelope takes about 26 ms to fall from 0.1 to
        // the closing level (10 ms × ln(0.1 / 0.00708)); the 100 ms hold
        // starts there, so the gate begins to close near 126 ms.
        let drop = opening.count
        #expect(output[drop + frames(milliseconds: 80)] == 0.001)
        #expect(output[drop + frames(milliseconds: 120)] == 0.001)
        #expect(output[drop + frames(milliseconds: 140)] < 0.001)
        #expect(output[drop + frames(milliseconds: 140)] > 0)
        #expect(output.last == 0)
    }

    @Test("the gate closes over the release time constant once the hold is over")
    func releaseClosesOverItsTimeConstant() {
        var effect = gate(hold: 100, release: 50)
        let opening = constant(0.1, milliseconds: 500)
        let quiet = constant(0.001, milliseconds: 1000)
        let output = run(&effect, [opening + quiet])[0]
        // Find where the gate lets go, then look one time constant later.
        let closing = output[opening.count...].firstIndex { $0 < 0.001 } ?? 0
        let closingAfter = Double(closing - opening.count) / sampleRate * 1000
        #expect(abs(closingAfter - (100 + 10 * log(0.1 / 0.00708))) < 1)
        let gain = Double(output[closing + frames(milliseconds: 50) - 1] / 0.001)
        #expect(abs(gain - exp(-1.0)) < 0.005)
    }

    @Test("with no hold the gate starts closing as soon as the detector falls under the closing level")
    func zeroHoldClosesSooner() {
        var effect = gate(hold: 0, release: 10)
        let opening = constant(0.1, milliseconds: 500)
        let output = run(&effect, [opening + constant(0.001, milliseconds: 1000)])[0]
        #expect(output[opening.count + frames(milliseconds: 20)] == 0.001)
        #expect(output[opening.count + frames(milliseconds: 40)] < 0.001)
        #expect(output.last == 0)
    }

    @Test("a signal that returns during the hold keeps the gate open and restarts the hold")
    func signalDuringHoldRestartsIt() {
        var effect = gate(hold: 100, release: 10)
        let word = constant(0.1, milliseconds: 200)
        let gap = constant(0.001, milliseconds: 90)
        let signal = word + gap + word + gap + word
        let output = run(&effect, [signal], blockSizes: unevenBlocks)[0]
        // Past the opening attack, the gate never moves: each 90 ms gap
        // is shorter than the hold.
        let settled = frames(milliseconds: 100)
        #expect(Array(output[settled...]) == Array(signal[settled...]))
    }

    @Test("a low note's zero crossings do not chatter the gate, even with no hold")
    func lowFrequencyDoesNotChatter() {
        var effect = gate(hold: 0, release: 10)
        let signal = [sine(frequency: 50, amplitude: 0.5, milliseconds: 1500)]
        let output = run(&effect, signal)
        let settled = frames(milliseconds: 500)
        #expect(Array(output[0][settled...]) == Array(signal[0][settled...]))
    }

    @Test("the range sets how far a closed gate turns the signal down")
    func rangeSetsClosedGain() {
        var effect = gate()
        effect.setParameters(["rangeDecibels": .double(-20)])
        let output = run(&effect, [constant(0.001, milliseconds: 1000)])[0]
        #expect(abs((output.last ?? 0) - 0.0001) < 1e-7)

        // A range of 0 dB is a gate that does nothing.
        var open = gate()
        open.setParameters(["rangeDecibels": .double(0)])
        let passed = run(&open, [constant(0.001, milliseconds: 1000)])[0]
        #expect(passed.last == 0.001)
    }

    @Test("one gain serves both channels, so a loud right opens the gate for a quiet left")
    func stereoIsLinked() {
        var effect = gate()
        let output = run(&effect, [constant(0.001, milliseconds: 500), constant(0.1, milliseconds: 500)])
        #expect(output[0].last == 0.001)
        #expect(output[1].last == 0.1)
    }

    @Test("the output is the same however the signal is cut into blocks")
    func blockBoundariesDoNotChangeTheOutput() {
        let burst = sine(frequency: 200, amplitude: 0.4, milliseconds: 150)
        let signal = [
            burst + constant(0.0005, milliseconds: 300) + burst + constant(0, milliseconds: 300),
            noise(amplitude: 0.004, count: frames(milliseconds: 900), seed: 23),
        ]
        var whole = GateEffect()
        var cut = GateEffect()
        let expected = run(&whole, signal, blockSizes: [signal[0].count])
        #expect(run(&cut, signal, blockSizes: unevenBlocks) == expected)
    }

    @Test("settings beyond their declared ranges are clamped")
    func settingsClampToRange() {
        // The threshold stops at 0 dB: 0.9 stays shut, full scale opens.
        var effect = GateEffect()
        effect.setParameters(["thresholdDecibels": .double(50)])
        #expect(run(&effect, [constant(0.9, milliseconds: 300)])[0].allSatisfy { $0 == 0 })
        #expect(run(&effect, [constant(1, milliseconds: 300)])[0].last == 1)

        // A range under −80 dB is the bottom of the range: silence.
        var silent = GateEffect()
        silent.setParameters(["rangeDecibels": .double(-300)])
        #expect(run(&silent, [constant(0.001, milliseconds: 300)])[0].allSatisfy { $0 == 0 })

        // The hold stops at 2000 ms and the release at 10 ms: 2.1 s after
        // the signal drops the gate is still open, at 2.5 s it is shut.
        var long = GateEffect()
        long.setParameters([
            "thresholdDecibels": .double(-40), "holdMilliseconds": .double(1_000_000_000),
            "releaseMilliseconds": .double(0),
        ])
        let opening = constant(0.1, milliseconds: 200)
        let output = run(&long, [opening + constant(0.001, milliseconds: 2500)])[0]
        #expect(output[opening.count + frames(milliseconds: 2000)] == 0.001)
        #expect(output.last == 0)
    }

    @Test("a hold shortened while it runs applies to the hold already running")
    func shortenedHoldAppliesAtOnce() {
        var effect = gate(hold: 2000, release: 10)
        _ = run(&effect, [constant(0.1, milliseconds: 200) + constant(0.001, milliseconds: 200)])
        effect.setParameters(["holdMilliseconds": .double(0)])
        let output = run(&effect, [constant(0.001, milliseconds: 500)])[0]
        #expect(output.last == 0)
    }

    @Test("a payload keeps the settings it omits, ignores unknown keys, and takes an integer")
    func payloadIsForgiving() {
        var effect = GateEffect()
        effect.setParameters(["thresholdDecibels": .int(-20)])
        effect.setParameters(["holdMilliseconds": .int(50), "somethingNewer": .string("x")])
        effect.setParameters(["thresholdDecibels": .string("high")])
        // Still −20 dB: 0.05 (−26 dB) stays shut, 0.2 (−14 dB) opens.
        #expect(run(&effect, [constant(0.05, milliseconds: 300)])[0].allSatisfy { $0 == 0 })
        #expect(run(&effect, [constant(0.2, milliseconds: 300)])[0].last == 0.2)
    }

    @Test("the provider builds the gate at the payload's settings, and at the defaults without one")
    func providerAppliesPayload() {
        var configured = GateEffectProvider().makeEffect(parameters: ["thresholdDecibels": .double(-20)])
        #expect(run(&configured, [constant(0.05, milliseconds: 300)])[0].allSatisfy { $0 == 0 })

        // The default −45 dB threshold: −50 dB stays shut, −40 dB opens.
        var fresh = GateEffectProvider().makeEffect(parameters: [:])
        #expect(run(&fresh, [constant(linear(-50), milliseconds: 300)])[0].allSatisfy { $0 == 0 })
        #expect(run(&fresh, [constant(linear(-40), milliseconds: 300)])[0].last == linear(-40))
    }

    @Test("a sample that is not finite never opens the gate")
    func nonFiniteSamplesDoNotOpen() {
        var effect = gate()
        var bad: [[Float]] = [[.infinity, .nan, -.infinity]]
        effect.process(&bad, sampleRate: sampleRate)
        let output = run(&effect, [constant(0.001, milliseconds: 300)])
        #expect(output[0].allSatisfy { $0 == 0 })
    }

    @Test("silence stays silence, and empty or uneven blocks keep their shape")
    func edgeShapes() {
        var effect = GateEffect()
        #expect(run(&effect, [constant(0, milliseconds: 50)])[0].allSatisfy { $0 == 0 })

        var none: [[Float]] = []
        effect.process(&none, sampleRate: sampleRate)
        #expect(none.isEmpty)

        var empty: [[Float]] = [[], []]
        effect.process(&empty, sampleRate: sampleRate)
        #expect(empty == [[], []])

        var uneven: [[Float]] = [[0.5, 0.5, 0.5], [0.5]]
        effect.process(&uneven, sampleRate: sampleRate)
        #expect(uneven.map(\.count) == [3, 1])
    }

    @Test("a sample rate of zero still gates, with no hold and the gain moving at once")
    func zeroSampleRateStillGates() {
        var effect = gate()
        var block: [[Float]] = [[0.5, 0.0001, 0.5]]
        effect.process(&block, sampleRate: 0)
        #expect(block == [[0.5, 0, 0.5]])
    }
}
