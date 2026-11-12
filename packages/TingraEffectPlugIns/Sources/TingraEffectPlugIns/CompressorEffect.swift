//
//  CompressorEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// The compressor's provider: evens out a channel strip's level by
/// turning down what rises over a threshold — the voice staple that
/// keeps a quiet aside and a laugh in the same range.
public struct CompressorEffectProvider: AudioEffectProvider {
    /// The compressor's stable identifier on the project/scripting
    /// contract.
    public static let effectID = EffectID(rawValue: "compressor")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Compressor"

    /// The six parameters, in the order an operator sets them: where
    /// compression starts, how hard, how fast it acts and lets go, how
    /// gradually it starts, and the gain that makes up what it took.
    public var parameters: [Parameter] {
        [
            Parameter(
                key: CompressorEffect.thresholdKey,
                name: "Threshold",
                range: CompressorEffect.thresholdRange,
                defaultValue: CompressorEffect.defaultThreshold,
                unit: "dB"
            ),
            // No unit: a ratio reads "3.0", and a host shows a unitless
            // value with a fraction digit, which a ratio needs.
            Parameter(
                key: CompressorEffect.ratioKey,
                name: "Ratio",
                range: CompressorEffect.ratioRange,
                defaultValue: CompressorEffect.defaultRatio,
                scale: .logarithmic
            ),
            Parameter(
                key: CompressorEffect.attackKey,
                name: "Attack",
                range: CompressorEffect.attackRange,
                defaultValue: CompressorEffect.defaultAttack,
                unit: "ms",
                scale: .logarithmic
            ),
            Parameter(
                key: CompressorEffect.releaseKey,
                name: "Release",
                range: CompressorEffect.releaseRange,
                defaultValue: CompressorEffect.defaultRelease,
                unit: "ms",
                scale: .logarithmic
            ),
            Parameter(
                key: CompressorEffect.kneeKey,
                name: "Knee",
                range: CompressorEffect.kneeRange,
                defaultValue: CompressorEffect.defaultKnee,
                unit: "dB"
            ),
            Parameter(
                key: CompressorEffect.makeupKey,
                name: "Makeup Gain",
                range: CompressorEffect.makeupRange,
                defaultValue: CompressorEffect.defaultMakeup,
                unit: "dB"
            ),
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's compressor at the payload's settings.
    public func makeEffect(parameters: [String: JSONValue]) -> any AudioEffect {
        var effect = CompressorEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// A feed-forward compressor with no latency: each sample's level over
/// the threshold is turned into a gain reduction by the ratio, the
/// reduction is smoothed by the attack and release times, and the makeup
/// gain is added back. One gain serves every channel
/// (``LinkedDynamics``), so a stereo strip's image holds still.
///
/// The level is the sample's own peak, not an average, and the smoothing
/// works on the reduction in decibels — so on a steady signal the
/// reduction settles exactly on the static curve
/// (``reduction(atLevel:)``), and on program material the attack and
/// release times shape how closely it follows. Both times are time
/// constants: the reduction covers 63 % of the way to its target in that
/// long.
public struct CompressorEffect: AudioEffect {
    /// The persisted parameter key of the threshold.
    static let thresholdKey = "thresholdDecibels"

    /// The persisted parameter key of the ratio.
    static let ratioKey = "ratio"

    /// The persisted parameter key of the attack time.
    static let attackKey = "attackMilliseconds"

    /// The persisted parameter key of the release time.
    static let releaseKey = "releaseMilliseconds"

    /// The persisted parameter key of the knee width.
    static let kneeKey = "kneeDecibels"

    /// The persisted parameter key of the makeup gain.
    static let makeupKey = "makeupDecibels"

    /// The thresholds the effect accepts, in decibels relative to full
    /// scale.
    static let thresholdRange: ClosedRange<Double> = -60...0

    /// The ratios the effect accepts — input decibels over the threshold
    /// per output decibel. `1` is no compression.
    static let ratioRange: ClosedRange<Double> = 1...20

    /// The attack times the effect accepts, in milliseconds.
    static let attackRange: ClosedRange<Double> = 1...200

    /// The release times the effect accepts, in milliseconds.
    static let releaseRange: ClosedRange<Double> = 10...2000

    /// The knee widths the effect accepts, in decibels. `0` is a hard
    /// knee.
    static let kneeRange: ClosedRange<Double> = 0...24

    /// The makeup gains the effect accepts, in decibels.
    static let makeupRange: ClosedRange<Double> = 0...24

    /// The default threshold in decibels.
    static let defaultThreshold: Double = -18

    /// The default ratio: gentle, a voice setting.
    static let defaultRatio: Double = 3

    /// The default attack time in milliseconds.
    static let defaultAttack: Double = 10

    /// The default release time in milliseconds.
    static let defaultRelease: Double = 150

    /// The default knee width in decibels.
    static let defaultKnee: Double = 6

    /// The default makeup gain: none, so a fresh compressor only ever
    /// turns down.
    static let defaultMakeup: Double = 0

    /// The threshold in decibels.
    private var threshold = Float(CompressorEffect.defaultThreshold)

    /// The share of the level over the threshold that is taken away:
    /// `1 − 1/ratio`, `0` at a ratio of 1.
    private var slope = Float(1 - 1 / CompressorEffect.defaultRatio)

    /// The knee width in decibels, centered on the threshold.
    private var knee = Float(CompressorEffect.defaultKnee)

    /// The linear level under which there is no reduction at all — the
    /// bottom of the knee — so a quiet sample costs no logarithm.
    private var onsetLevel = LinkedDynamics.linear(
        fromDecibels: CompressorEffect.defaultThreshold - CompressorEffect.defaultKnee / 2)

    /// The makeup gain as a linear factor.
    private var makeup: Float = 1

    /// The attack time constant in milliseconds.
    private var attack = CompressorEffect.defaultAttack

    /// The release time constant in milliseconds.
    private var release = CompressorEffect.defaultRelease

    /// The sample rate the smoothing coefficients were last computed at,
    /// or nil when they must be recomputed at the next block.
    private var computedForSampleRate: Double?

    /// The fraction of its distance to a larger reduction the envelope
    /// keeps each sample.
    private var attackCoefficient: Double = 0

    /// The fraction of its distance to a smaller reduction the envelope
    /// keeps each sample.
    private var releaseCoefficient: Double = 0

    /// The smoothed gain reduction in decibels, zero or more — the state
    /// carried from one block to the next.
    private var envelope: Double = 0

    /// Creates the compressor at its default settings.
    public init() {}

    /// Reads new settings from the payload, each clamped to its declared
    /// range; an absent or non-numeric key keeps the current value. The
    /// current reduction is kept, so a drag never clicks.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let decibels = parameters[Self.thresholdKey]?.doubleValue {
            threshold = Float(Self.thresholdRange.clamping(decibels))
        }
        if let ratio = parameters[Self.ratioKey]?.doubleValue {
            slope = Float(1 - 1 / Self.ratioRange.clamping(ratio))
        }
        if let decibels = parameters[Self.kneeKey]?.doubleValue {
            knee = Float(Self.kneeRange.clamping(decibels))
        }
        if let decibels = parameters[Self.makeupKey]?.doubleValue {
            makeup = LinkedDynamics.linear(fromDecibels: Self.makeupRange.clamping(decibels))
        }
        if let milliseconds = parameters[Self.attackKey]?.doubleValue {
            attack = Self.attackRange.clamping(milliseconds)
            computedForSampleRate = nil
        }
        if let milliseconds = parameters[Self.releaseKey]?.doubleValue {
            release = Self.releaseRange.clamping(milliseconds)
            computedForSampleRate = nil
        }
        onsetLevel = LinkedDynamics.linear(fromDecibels: Double(threshold - knee / 2))
    }

    /// The static curve: the gain reduction in decibels, zero or more,
    /// the compressor settles on for a steady level. Under the knee
    /// there is none; over it the level's excess is cut by
    /// `1 − 1/ratio`; across the knee the two are joined by a quadratic,
    /// so compression eases in.
    ///
    /// - Parameter level: The signal level in decibels relative to full
    ///   scale.
    func reduction(atLevel level: Float) -> Float {
        let over = level - threshold
        if 2 * over <= -knee {
            return 0
        }
        if 2 * over < knee {
            let intoKnee = over + knee / 2
            return slope * intoKnee * intoKnee / (2 * knee)
        }
        return slope * over
    }

    /// Compresses the block in place. A sample rate of zero or less
    /// still compresses — the reduction then follows the level at once.
    public mutating func process(_ channels: inout [[Float]], sampleRate: Double) {
        if computedForSampleRate != sampleRate {
            attackCoefficient = LinkedDynamics.smoothingCoefficient(milliseconds: attack, sampleRate: sampleRate)
            releaseCoefficient = LinkedDynamics.smoothingCoefficient(milliseconds: release, sampleRate: sampleRate)
            computedForSampleRate = sampleRate
        }
        let settings = self
        var envelope = envelope
        LinkedDynamics.apply(to: &channels) { level in
            let target = level > settings.onsetLevel ? Double(settings.reduction(atLevel: 20 * log10(level))) : 0
            let coefficient = target > envelope ? settings.attackCoefficient : settings.releaseCoefficient
            envelope = target + (envelope - target) * coefficient
            if target == 0, envelope < LinkedDynamics.settledEpsilon {
                // Fully released: back to exactly none, out of denormal
                // arithmetic, and no power function per sample.
                envelope = 0
                return settings.makeup
            }
            return settings.makeup * Float(pow(10, -envelope / 20))
        }
        self.envelope = envelope
    }
}
