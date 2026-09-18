//
//  Parameter.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// One adjustable parameter a plug-in declares for something it registers
/// — the descriptor a host UI draws a control from (a slider with a range,
/// a default, a unit; a color well) without knowing the concrete plug-in
/// (ARCHITECTURE.md, "The effect seam"; PLUGINS.md, Decision 15). Effects
/// declared parameters first; every host-tier registration declares them
/// the same way through ``ParameterDescribing`` — an input's frequency, an
/// output's stream name — so a host-only plug-in gets a native settings
/// pane with no UI code of its own.
///
/// The ``key`` is the parameter's name in the persisted payload — an
/// effect's ``EffectConfiguration/parameters``, an input's stored
/// settings, a ``Destination/parameters`` — a stable camelCase name on the
/// project/scripting contract, like the plug-in's own identifier. A
/// parameter is numeric by default; a **color** parameter (``Kind/color``,
/// added 2026-09-09 for the Frame effect's border) carries a
/// ``ParameterColor`` in the payload instead, and a host draws a color well
/// for it. The kind joined the descriptor additively — every numeric
/// conformer and call site is unchanged — as the stability rules ask.
///
/// Named `EffectParameter` until 2026-09-15, when the declaration widened
/// past effects; the old name remains as a deprecated alias.
public struct Parameter: Sendable, Equatable {
    /// What kind of value the parameter takes, and so which control a host
    /// draws for it.
    public enum Kind: Sendable, Equatable {
        /// A `Double` within ``Parameter/range`` — a slider.
        case number

        /// A ``ParameterColor`` — a color well. ``Parameter/range`` and
        /// ``Parameter/defaultValue`` are meaningless for a color and
        /// hold `0`…`1` and `0`; ``Parameter/defaultColor`` is the
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
    /// typically the neutral setting, so an empty payload changes nothing.
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
    public let defaultColor: ParameterColor?

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
    public init(key: String, name: String, defaultColor: ParameterColor) {
        self.key = key
        self.name = name
        self.range = 0...1
        self.defaultValue = 0
        self.unit = nil
        self.scale = .linear
        self.kind = .color
        self.defaultColor = defaultColor
    }

    /// The numeric value a payload holds for this parameter, or the
    /// declared default when the payload omits the key or holds something
    /// that is not a number — the one reading rule every host control and
    /// every conformer's `setParameters` share, so a payload's `6` and
    /// `6.0` mean the same thing everywhere (``JSONValue/doubleValue``).
    ///
    /// - Parameter payload: The persisted parameter payload.
    /// - Returns: The value, unclamped — a host clamps at the control, a
    ///   conformer where it applies the value.
    public func value(in payload: [String: JSONValue]) -> Double {
        payload[key]?.doubleValue ?? defaultValue
    }

    /// The value clamped into ``range`` — what a host does at the control
    /// and a conformer where it applies a value, so a payload written by
    /// hand can never push a parameter past what it declared.
    ///
    /// - Parameter value: A value to clamp.
    /// - Returns: The nearest value within ``range``.
    public func clamped(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// The color a payload holds for this parameter, or the declared
    /// default color when the payload omits the key or holds something that
    /// is not a color object; nil for a numeric parameter, which declares
    /// no default color.
    ///
    /// - Parameter payload: The persisted parameter payload.
    /// - Returns: The color, or nil for a ``Kind/number`` parameter.
    public func color(in payload: [String: JSONValue]) -> ParameterColor? {
        payload[key].flatMap(ParameterColor.init) ?? defaultColor
    }
}

/// The name ``Parameter`` carried while only effects declared parameters.
@available(*, deprecated, renamed: "Parameter")
public typealias EffectParameter = Parameter
