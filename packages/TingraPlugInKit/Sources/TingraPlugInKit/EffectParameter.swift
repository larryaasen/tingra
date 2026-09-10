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
/// A parameter is numeric by default; a **color** parameter
/// (``Kind/color``, added 2026-09-09 for the Frame effect's border) carries
/// an ``EffectColor`` in the payload instead, and a host draws a color well
/// for it. The kind joined the descriptor additively — every numeric
/// conformer and call site is unchanged — as the stability rules ask.
public struct EffectParameter: Sendable, Equatable {
    /// What kind of value the parameter takes, and so which control a host
    /// draws for it.
    public enum Kind: Sendable, Equatable {
        /// A `Double` within ``EffectParameter/range`` — a slider.
        case number

        /// An ``EffectColor`` — a color well. ``EffectParameter/range`` and
        /// ``EffectParameter/defaultValue`` are meaningless for a color and
        /// hold `0`…`1` and `0`; ``EffectParameter/defaultColor`` is the
        /// default instead.
        case color
    }

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

    /// What kind of value the parameter takes (default ``Kind/number``).
    public let kind: Kind

    /// The color the parameter takes when the payload omits its key — set
    /// for a ``Kind/color`` parameter, nil for a numeric one.
    public let defaultColor: EffectColor?

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
        self.kind = .number
        self.defaultColor = nil
    }

    /// Creates a color parameter descriptor — a ``Kind/color`` parameter a
    /// host draws a color well for.
    ///
    /// - Parameters:
    ///   - key: The parameter's stable key in the persisted payload.
    ///   - name: A short user-facing name.
    ///   - defaultColor: The color used when the payload omits the key.
    public init(key: String, name: String, defaultColor: EffectColor) {
        self.key = key
        self.name = name
        self.range = 0...1
        self.defaultValue = 0
        self.unit = nil
        self.scale = .linear
        self.kind = .color
        self.defaultColor = defaultColor
    }
}
