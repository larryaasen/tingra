//
//  LowPassEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// The low-pass filter's provider: rolls off a channel strip's signal
/// above the cutoff — taming hiss and harshness before the fader.
public struct LowPassEffectProvider: AudioEffectProvider {
    /// The low-pass effect's stable identifier on the project/scripting
    /// contract.
    public static let effectID = EffectID(rawValue: "lowPass")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Low-Pass Filter"

    /// The one parameter: the cutoff frequency, on a logarithmic control
    /// (equal travel is equal ratios, the way frequency is heard).
    public var parameters: [EffectParameter] {
        [
            EffectParameter(
                key: LowPassEffect.cutoffKey,
                name: "Cutoff",
                range: LowPassEffect.cutoffRange,
                defaultValue: 12000,
                unit: "Hz",
                scale: .logarithmic
            )
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's low-pass instance at the payload's cutoff.
    public func makeEffect(parameters: [String: JSONValue]) -> any AudioEffect {
        var effect = LowPassEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// A second-order Butterworth low-pass over the strip's block — the
/// shared ``BiquadFilter`` carries the DSP and the per-channel memory.
public struct LowPassEffect: AudioEffect {
    /// The persisted parameter key of the cutoff.
    static let cutoffKey = "cutoffHertz"

    /// The cutoffs the effect accepts, in hertz.
    static let cutoffRange: ClosedRange<Double> = 200...20000

    /// The biquad carrying the coefficients and filter memory.
    private var filter = BiquadFilter(kind: .lowPass, cutoff: 12000)

    /// Creates the effect at the default 12 kHz cutoff.
    public init() {}

    /// Reads a new `cutoffHertz` from the payload, clamped to the declared
    /// range; an absent or non-numeric key keeps the current cutoff.
    /// Filter memory is kept, so a cutoff sweep stays click-free.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        guard let cutoff = parameters[Self.cutoffKey]?.doubleValue else { return }
        filter.setCutoff(min(Self.cutoffRange.upperBound, max(Self.cutoffRange.lowerBound, cutoff)))
    }

    /// Filters the block in place.
    public mutating func process(_ channels: inout [[Float]], sampleRate: Double) {
        filter.process(&channels, sampleRate: sampleRate)
    }
}
