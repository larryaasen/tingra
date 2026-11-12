//
//  LimiterEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// The limiter's provider: holds a channel strip's signal at or under a
/// ceiling, so a shout or a loud chord never clips the strip.
public struct LimiterEffectProvider: AudioEffectProvider {
    /// The limiter's stable identifier on the project/scripting contract.
    public static let effectID = EffectID(rawValue: "limiter")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Limiter"

    /// The two parameters: the ceiling no sample leaves above, and how
    /// fast the gain recovers once the signal falls back under it.
    public var parameters: [Parameter] {
        [
            Parameter(
                key: LimiterEffect.ceilingKey,
                name: "Ceiling",
                range: LimiterEffect.ceilingRange,
                defaultValue: LimiterEffect.defaultCeiling,
                unit: "dB"
            ),
            Parameter(
                key: LimiterEffect.releaseKey,
                name: "Release",
                range: LimiterEffect.releaseRange,
                defaultValue: LimiterEffect.defaultRelease,
                unit: "ms",
                scale: .logarithmic
            ),
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's limiter at the payload's settings.
    public func makeEffect(parameters: [String: JSONValue]) -> any AudioEffect {
        var effect = LimiterEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// A peak limiter with no latency: the gain drops at once, on the very
/// sample that would pass the ceiling, and recovers over the release
/// time. One gain serves every channel (``LinkedDynamics``), so a stereo
/// strip's image holds still.
///
/// **The ceiling is a guarantee on the strip's samples.** The gain
/// applied to a sample is never more than the ceiling divided by that
/// sample's level, and a last clamp covers float rounding and samples
/// that are not finite — so every sample this effect returns is finite
/// and within the ceiling, whatever came in. Three limits follow from
/// where the effect sits and what it measures, and are stated rather than
/// hidden: it measures sample peaks, not the peaks a converter
/// reconstructs between samples, which is why the default ceiling leaves
/// 1 dB of room; a chain runs before the strip's fader, so a fader above
/// unity raises the signal past the ceiling again; and it limits one
/// strip, not the sum of several.
///
/// The gain falling at once is what a limiter with no look-ahead costs:
/// a hard peak is turned down within one sample, which is audible as
/// distortion when the limiter is driven hard. It is a safety net under
/// a sensible level, not a loudness maximizer.
public struct LimiterEffect: AudioEffect {
    /// The persisted parameter key of the ceiling.
    static let ceilingKey = "ceilingDecibels"

    /// The persisted parameter key of the release time.
    static let releaseKey = "releaseMilliseconds"

    /// The ceilings the effect accepts, in decibels relative to full
    /// scale.
    static let ceilingRange: ClosedRange<Double> = -24...0

    /// The release times the effect accepts, in milliseconds.
    static let releaseRange: ClosedRange<Double> = 10...1000

    /// The default ceiling: 1 dB under full scale, room for the peaks
    /// between samples.
    static let defaultCeiling: Double = -1

    /// The default release time in milliseconds.
    static let defaultRelease: Double = 100

    /// The ceiling as a linear sample magnitude.
    private var ceiling = Double(LinkedDynamics.linear(fromDecibels: LimiterEffect.defaultCeiling))

    /// The release time constant in milliseconds.
    private var release = LimiterEffect.defaultRelease

    /// The sample rate the release coefficient was last computed at, or
    /// nil when it must be recomputed at the next block.
    private var computedForSampleRate: Double?

    /// The fraction of its distance to unity the gain keeps each sample
    /// while it recovers.
    private var releaseCoefficient: Double = 0

    /// The gain the limiter is applying right now (`1` is no limiting) —
    /// the state carried from one block to the next.
    private var gain: Double = 1

    /// Creates the limiter at its default ceiling and release.
    public init() {}

    /// Reads a new ceiling and release from the payload, each clamped to
    /// its declared range; an absent or non-numeric key keeps the current
    /// value. The current gain is kept, so a drag never clicks.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let decibels = parameters[Self.ceilingKey]?.doubleValue {
            ceiling = Double(LinkedDynamics.linear(fromDecibels: Self.ceilingRange.clamping(decibels)))
        }
        if let milliseconds = parameters[Self.releaseKey]?.doubleValue {
            release = Self.releaseRange.clamping(milliseconds)
            computedForSampleRate = nil
        }
    }

    /// Limits the block in place. A sample rate of zero or less still
    /// limits — the gain then recovers at once rather than over time.
    public mutating func process(_ channels: inout [[Float]], sampleRate: Double) {
        if computedForSampleRate != sampleRate {
            releaseCoefficient = LinkedDynamics.smoothingCoefficient(milliseconds: release, sampleRate: sampleRate)
            computedForSampleRate = sampleRate
        }
        let ceiling = ceiling
        let coefficient = releaseCoefficient
        var gain = gain
        LinkedDynamics.apply(to: &channels) { level in
            let level = Double(level)
            let target = level > ceiling ? ceiling / level : 1
            if target < gain {
                // Attack: at once, so this sample is already within the
                // ceiling.
                gain = target
            } else {
                // Release: toward the target from below, so the gain
                // never passes what this sample allows.
                gain = target + (gain - target) * coefficient
                if target - gain < LinkedDynamics.settledEpsilon {
                    gain = target
                }
            }
            return Float(gain)
        }
        self.gain = gain
        let limit = Float(ceiling)

        // The guarantee's last line: float rounding can land a sample a
        // hair over, and a sample that was not finite is not made finite
        // by a gain.
        for c in channels.indices {
            channels[c].withUnsafeMutableBufferPointer { samples in
                for i in samples.indices where !(abs(samples[i]) <= limit) {
                    samples[i] = samples[i].isNaN ? 0 : (samples[i] < 0 ? -limit : limit)
                }
            }
        }
    }
}
