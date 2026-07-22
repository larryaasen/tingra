//
//  GainEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// The gain effect's provider: a clean decibel trim on a channel strip —
/// the simplest audio staple, and the seam's reference conformance.
public struct GainEffectProvider: AudioEffectProvider {
    /// The gain effect's stable identifier on the project/scripting
    /// contract.
    public static let effectID = EffectID(rawValue: "gain")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Gain"

    /// The one parameter: the trim in decibels, `0` (unity) by default.
    public var parameters: [EffectParameter] {
        [
            EffectParameter(
                key: GainEffect.gainKey,
                name: "Gain",
                range: GainEffect.gainRange,
                defaultValue: 0,
                unit: "dB"
            )
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's gain instance at the payload's trim.
    public func makeEffect(parameters: [String: JSONValue]) -> any AudioEffect {
        var effect = GainEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// A decibel trim applied to every sample of the strip's block — stateless
/// DSP, so the struct's only state is the current linear gain.
public struct GainEffect: AudioEffect {
    /// The persisted parameter key of the trim.
    static let gainKey = "gainDecibels"

    /// The trims the effect accepts, in decibels.
    static let gainRange: ClosedRange<Double> = -24...24

    /// The current trim as a linear factor (`1` is unity).
    private var linearGain: Float = 1

    /// Creates the effect at unity.
    public init() {}

    /// Reads a new `gainDecibels` from the payload, clamped to the
    /// declared range; an absent or non-numeric key keeps the current trim.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        guard let decibels = parameters[Self.gainKey]?.doubleValue else { return }
        let clamped = min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, decibels))
        linearGain = Float(pow(10, clamped / 20))
    }

    /// Scales every sample by the current linear gain, in place.
    public func process(_ channels: inout [[Float]], sampleRate: Double) {
        guard linearGain != 1 else { return }
        for c in channels.indices {
            for i in channels[c].indices {
                channels[c][i] *= linearGain
            }
        }
    }
}
