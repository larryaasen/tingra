//
//  CommittingNumberField.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// A numeric field that commits **once**, on Return or when focus leaves —
/// never per keystroke. SwiftUI's `TextField(value:format:)` pushes every
/// parseable keystroke into its binding, which for a clamped value is
/// unusable: typing "4" for a height of 400 committed 4, the minimum
/// clamped it to 22, the field reset to "22", and the next key appended
/// to that (Larry, 2026-09-10) — and every keystroke was a tap and an
/// undo step besides. The field keeps its own text while it has focus,
/// parses on commit in the user's locale, and refreshes its text
/// whenever the value changes from outside (a slider, a stepper, undo).
/// Every numeric field in the inspector and the chain editors is one of
/// these.
struct CommittingNumberField: View {
    /// The value the field shows.
    let value: Double

    /// The fraction digits shown and accepted.
    let fractionDigits: Int

    /// The accessibility label.
    let label: Text

    /// Called once with the parsed value when a commit changes it.
    let onCommit: (Double) -> Void

    /// The text being edited.
    @State private var text = ""

    /// Whether the field has keyboard focus — losing it commits.
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(text: $text) { label }
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: value, initial: true) { _, newValue in
                text = Self.formatted(newValue, fractionDigits: fractionDigits)
            }
    }

    /// Parses the text and hands a changed value out; unparseable text
    /// reverts to the value.
    private func commit() {
        guard let parsed = Self.parse(text) else {
            text = Self.formatted(value, fractionDigits: fractionDigits)
            return
        }
        if parsed != value {
            onCommit(parsed)
        }
        // The holder may clamp: show what was kept, not what was typed.
        text = Self.formatted(value, fractionDigits: fractionDigits)
    }

    /// The value as the field shows it.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - fractionDigits: The fraction digits to show.
    static func formatted(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    /// The typed text as a number in the user's locale (a grouping
    /// separator and a locale decimal mark are fine), or nil when it is
    /// not one. The parse strategy reads a leading number and ignores what
    /// follows ("4x" would be 4), so the text is first checked to hold
    /// nothing but number characters.
    ///
    /// - Parameter text: The typed text.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(isNumberCharacter) else { return nil }
        return try? Double(trimmed, format: .number, lenient: false)
    }

    /// Whether a character can appear in a typed number: a digit, a sign,
    /// or the locale's decimal or grouping separator.
    ///
    /// - Parameter character: The character.
    private static func isNumberCharacter(_ character: Character) -> Bool {
        if character.isNumber || character == "-" || character == "+" { return true }
        let text = String(character)
        return text == Locale.current.decimalSeparator || text == Locale.current.groupingSeparator
    }
}
