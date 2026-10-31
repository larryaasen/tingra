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
/// Three more joined the same way on 2026-10-27 for camera controls
/// (docs/UVC.md): a **toggle** parameter (``Kind/toggle``) carries a JSON
/// boolean and a host draws a switch; a parameter may name the
/// ``section`` it is grouped under; and a parameter may name the toggle
/// that hands it to the device's automatic control
/// (``automaticToggleKey``), so a host disables its control while that
/// toggle is on. The last two are set with modifiers
/// (``inSection(_:)``, ``controlledAutomatically(whenOn:)``), so no
/// existing initializer changed. A number may also declare the ``step``
/// its values move in (``stepped(by:)``), so a slider lands only on values
/// the device takes — a camera's pan moves in whole degrees, and a slider
/// that left it at -0.003° showed "-0°".
///
/// A **choice** parameter (``Kind/choice``) joined the same way on
/// 2026-10-30 for a camera's power line frequency: its value is one of a
/// list of named options, and a host draws a pop-up menu.
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

        /// On or off — a switch. The payload carries a JSON boolean;
        /// ``Parameter/range`` is `0`…`1` and ``Parameter/defaultValue``
        /// is `1` for on and `0` for off, so a host that reads it as a
        /// number still gets an honest answer. Read it with
        /// ``Parameter/isOn(in:)``.
        case toggle

        /// One of ``Parameter/choices`` — a pop-up menu. The payload carries
        /// the option's ``Choice/value`` as a number;
        /// ``Parameter/range`` spans the options' values. Read it with
        /// ``Parameter/choice(in:)``.
        case choice
    }

    /// One named option of a ``Kind/choice`` parameter.
    public struct Choice: Sendable, Equatable {
        /// The number the payload carries for this option.
        public let value: Double

        /// A short user-facing name, e.g. "60 Hz".
        public let name: String

        /// Creates an option.
        ///
        /// - Parameters:
        ///   - value: The number the payload carries for this option.
        ///   - name: A short user-facing name.
        public init(value: Double, name: String) {
            self.value = value
            self.name = name
        }
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

    /// A short user-facing heading the parameter is grouped under, e.g.
    /// "White Balance", or nil for none. A host groups consecutive
    /// parameters that share a section under one heading, in declaration
    /// order. Set with ``inSection(_:)``.
    public private(set) var section: String?

    /// The key of a ``Kind/toggle`` parameter that, while on, hands this
    /// parameter to the device's automatic control — a white balance
    /// temperature while auto white balance is on — or nil when nothing
    /// governs it. A host disables this parameter's control while that
    /// toggle is on, and a conformer does not apply the value then. Set with
    /// ``controlledAutomatically(whenOn:)``.
    public private(set) var automaticToggleKey: String?

    /// The increment a number's values move in from the bottom of its
    /// range — `1` for a camera's brightness, `10` for a white balance
    /// temperature in kelvin — or nil for a continuous parameter. A host
    /// snaps a control's values to it (``snapped(_:)``; ``ParameterScale``
    /// does so for every slider). Set with ``stepped(by:)``.
    public private(set) var step: Double?

    /// The options of a ``Kind/choice`` parameter, in display order; empty
    /// for every other kind.
    public private(set) var choices: [Choice] = []

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

    /// Creates a toggle parameter descriptor — a ``Kind/toggle`` parameter a
    /// host draws a switch for.
    ///
    /// - Parameters:
    ///   - key: The parameter's stable key in the persisted payload.
    ///   - name: A short user-facing name.
    ///   - defaultIsOn: Whether the toggle is on when the payload omits the
    ///     key.
    public init(key: String, name: String, defaultIsOn: Bool) {
        self.key = key
        self.name = name
        self.range = 0...1
        self.defaultValue = defaultIsOn ? 1 : 0
        self.unit = nil
        self.scale = .linear
        self.kind = .toggle
        self.defaultColor = nil
    }

    /// Creates a choice parameter descriptor — a ``Kind/choice`` parameter a
    /// host draws a pop-up menu for.
    ///
    /// - Parameters:
    ///   - key: The parameter's stable key in the persisted payload.
    ///   - name: A short user-facing name.
    ///   - choices: The options, in display order.
    ///   - defaultValue: The option's value used when the payload omits the
    ///     key or holds a value no option has.
    public init(key: String, name: String, choices: [Choice], defaultValue: Double) {
        let values = choices.map(\.value)
        self.key = key
        self.name = name
        self.range = (values.min() ?? defaultValue)...(values.max() ?? defaultValue)
        self.defaultValue = defaultValue
        self.unit = nil
        self.scale = .linear
        self.kind = .choice
        self.defaultColor = nil
        self.choices = choices
    }

    /// The same parameter, grouped under a section heading.
    ///
    /// - Parameter section: The short user-facing heading.
    /// - Returns: A copy with ``section`` set.
    public func inSection(_ section: String) -> Parameter {
        var copy = self
        copy.section = section
        return copy
    }

    /// The same parameter, governed by a toggle that hands it to the
    /// device's automatic control while on.
    ///
    /// - Parameter toggleKey: The key of the governing ``Kind/toggle``
    ///   parameter, declared by the same conformer.
    /// - Returns: A copy with ``automaticToggleKey`` set.
    public func controlledAutomatically(whenOn toggleKey: String) -> Parameter {
        var copy = self
        copy.automaticToggleKey = toggleKey
        return copy
    }

    /// The same parameter, moving in steps of a fixed increment from the
    /// bottom of its range.
    ///
    /// - Parameter step: The increment; a step that is not positive leaves
    ///   the parameter continuous.
    /// - Returns: A copy with ``step`` set.
    public func stepped(by step: Double) -> Parameter {
        var copy = self
        copy.step = step > 0 ? step : nil
        return copy
    }

    /// A value clamped into ``range`` and, for a parameter that declares a
    /// ``step``, moved to the nearest step from the bottom of the range —
    /// what a host does with a slider's value, so a control never rests
    /// between two values the device takes.
    ///
    /// - Parameter value: A value to snap.
    /// - Returns: The nearest value the parameter takes.
    public func snapped(_ value: Double) -> Double {
        let clamped = clamped(value)
        guard let step else { return clamped }
        let steps = ((clamped - range.lowerBound) / step).rounded()
        return self.clamped(range.lowerBound + steps * step)
    }

    /// Whether a payload holds this toggle on — its boolean, a number read
    /// as on when non-zero, or the declared default when the payload omits
    /// the key or holds something else; nil for a parameter that is not a
    /// ``Kind/toggle``.
    ///
    /// - Parameter payload: The persisted parameter payload.
    /// - Returns: Whether the toggle is on, or nil for another kind.
    public func isOn(in payload: [String: JSONValue]) -> Bool? {
        guard kind == .toggle else { return nil }
        if let isOn = payload[key]?.boolValue { return isOn }
        if let number = payload[key]?.doubleValue { return number != 0 }
        return defaultValue != 0
    }

    /// The option a payload holds — the one whose value it carries, or the
    /// default option when the payload omits the key or holds a value no
    /// option has; nil for a parameter with no such option, which every
    /// parameter that is not a ``Kind/choice`` is.
    ///
    /// - Parameter payload: The persisted parameter payload.
    /// - Returns: The option, or nil.
    public func choice(in payload: [String: JSONValue]) -> Choice? {
        let value = value(in: payload)
        return choices.first { $0.value == value } ?? choices.first { $0.value == defaultValue }
    }

    /// Whether the parameter's governing toggle is on in a payload, so its
    /// value belongs to the device's automatic control — false when no
    /// toggle governs it.
    ///
    /// - Parameters:
    ///   - payload: The persisted parameter payload.
    ///   - parameters: The declaring conformer's parameters, where the
    ///     governing toggle is found.
    /// - Returns: Whether an automatic toggle owns the value right now.
    public func isControlledAutomatically(in payload: [String: JSONValue], among parameters: [Parameter]) -> Bool {
        guard let automaticToggleKey,
            let toggle = parameters.first(where: { $0.key == automaticToggleKey })
        else { return false }
        return toggle.isOn(in: payload) ?? false
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
