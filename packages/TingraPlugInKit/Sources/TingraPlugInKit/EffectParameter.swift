//
//  EffectParameter.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// One adjustable parameter an effect declares — the descriptor a provider
/// publishes so a host UI can draw a control for it (a slider with a range,
/// a default, a unit) without knowing the concrete effect
/// (ARCHITECTURE.md, "The effect seam"). Third-party effects get parameter
/// UI for free by declaring their parameters here.
///
/// The ``key`` is the parameter's name in the effect's persisted
/// ``EffectConfiguration/parameters`` payload — a stable camelCase name on
/// the project/scripting contract, like the effect's ``EffectID``.
/// V1 parameters are numeric (`Double`); richer value kinds (colors,
/// strings) can join the descriptor later without breaking conformers.
public struct EffectParameter: Sendable, Equatable {
    /// How a control maps its travel onto the parameter's range.
    public enum Scale: Sendable, Equatable {
        /// Equal control travel covers equal value spans — right for
        /// levels and balances.
        case linear

        /// Equal control travel covers equal ratios — right for
        /// frequencies, where 100→200 Hz should feel like 1→2 kHz.
        case logarithmic
    }

    /// The parameter's stable camelCase key in the persisted payload,
    /// e.g. `gainDecibels`, `cutoffHertz`.
    public let key: String

    /// A short user-facing name, e.g. "Gain".
    public let name: String

    /// The values the parameter accepts, as a closed range.
    public let range: ClosedRange<Double>

    /// The value the parameter takes when the payload omits its key —
    /// typically the neutral setting, so an empty payload is a no-op effect.
    public let defaultValue: Double

    /// A short unit label shown beside the control (`dB`, `Hz`), or nil
    /// for a unitless parameter.
    public let unit: String?

    /// How a control maps onto ``range``.
    public let scale: Scale

    /// Creates a parameter descriptor.
    ///
    /// - Parameters:
    ///   - key: The parameter's stable key in the persisted payload.
    ///   - name: A short user-facing name.
    ///   - range: The values the parameter accepts.
    ///   - defaultValue: The value used when the payload omits the key.
    ///   - unit: A short unit label, or nil (default) for unitless.
    ///   - scale: How a control maps onto the range (default linear).
    public init(
        key: String,
        name: String,
        range: ClosedRange<Double>,
        defaultValue: Double,
        unit: String? = nil,
        scale: Scale = .linear
    ) {
        self.key = key
        self.name = name
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
        self.scale = scale
    }
}
