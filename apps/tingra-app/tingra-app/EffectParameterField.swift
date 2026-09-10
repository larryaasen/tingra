//
//  EffectParameterField.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The editable value field both chain editors draw beside a number
/// parameter's slider (ARCHITECTURE.md, "Effect parameters show and take
/// their value"): the slider for feel, the field for knowing and typing,
/// the unit beside it — the way Keynote and Final Cut Pro draw every
/// numeric inspector property, and the way the layer inspector already
/// draws Opacity. A typed value is clamped to the parameter's declared
/// range and committed once, on Return or focus loss (a
/// ``CommittingNumberField``); the caller wires the commit to its model
/// (one undo step, one `tap`).
struct EffectParameterField: View {
    /// The parameter the field edits: its range, unit, and name.
    let parameter: EffectParameter

    /// The parameter's current stored value.
    let value: Double

    /// Called once with the clamped stored value when a typed value
    /// differs from the current one.
    let onCommit: (Double) -> Void

    /// The field's width: room for a five-digit cutoff in hertz.
    private static let fieldWidth: CGFloat = 52

    var body: some View {
        HStack(spacing: 2) {
            CommittingNumberField(
                value: EffectParameterFormat.displayValue(value, for: parameter),
                fractionDigits: EffectParameterFormat.fractionDigits(for: parameter),
                label: Text(parameter.name)
            ) { typed in
                let stored = EffectParameterFormat.storedValue(typed, for: parameter)
                guard stored != value else { return }
                onCommit(stored)
            }
            .monospacedDigit()
            .frame(width: Self.fieldWidth)
            .accessibilityLabel(parameter.name)

            if let unit = parameter.unit {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The pure conversions between a parameter's stored value and the value a
/// person reads and types (ARCHITECTURE.md, "Effect parameters show and
/// take their value"). One rule a third-party effect author can follow:
/// declare the unit `%` and store a fraction, and the host shows and takes
/// percent.
enum EffectParameterFormat {
    /// The unit that marks a stored fraction shown as percent.
    static let percentUnit = "%"

    /// Whether the parameter stores a fraction that displays as percent.
    ///
    /// - Parameter parameter: The parameter.
    static func isPercent(_ parameter: EffectParameter) -> Bool {
        parameter.unit == percentUnit
    }

    /// The value a person reads: a percent parameter's fraction times a
    /// hundred, any other value as stored.
    ///
    /// - Parameters:
    ///   - stored: The stored value.
    ///   - parameter: The parameter it belongs to.
    static func displayValue(_ stored: Double, for parameter: EffectParameter) -> Double {
        isPercent(parameter) ? stored * 100 : stored
    }

    /// The value to store for what a person typed: a percent parameter's
    /// number divided by a hundred, any other as typed — then clamped to
    /// the parameter's declared range, so a typed value can never leave
    /// the range a slider keeps.
    ///
    /// - Parameters:
    ///   - typed: The typed value.
    ///   - parameter: The parameter it belongs to.
    static func storedValue(_ typed: Double, for parameter: EffectParameter) -> Double {
        let stored = isPercent(parameter) ? typed / 100 : typed
        return min(parameter.range.upperBound, max(parameter.range.lowerBound, stored))
    }

    /// The fraction digits the field shows: none with a unit (a percent,
    /// a pixel, a decibel, a hertz), one without.
    ///
    /// - Parameter parameter: The parameter.
    static func fractionDigits(for parameter: EffectParameter) -> Int {
        parameter.unit == nil ? 1 : 0
    }
}
