//
//  EffectParameterPicker.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The control every generic parameter editor draws for a choice parameter
/// (`Parameter.Kind.choice`, docs/UVC.md): the parameter's name beside a
/// pop-up menu of its declared options, shared by the input settings popover
/// and both effect chain editors so they cannot drift.
///
/// A pick is one discrete change, like a toggle's flip, so the caller reports
/// its `tap` and applies the option's value in `onChange`.
struct EffectParameterPicker: View {
    /// The parameter the menu edits, for its name and options.
    let parameter: Parameter

    /// The option currently in force, or nil when the parameter declares none.
    let selection: Parameter.Choice?

    /// Called with the picked option when the operator chooses one.
    let onChange: (Parameter.Choice) -> Void

    /// The name, then the menu of the parameter's options in declared order.
    var body: some View {
        Picker(
            selection: Binding {
                selection?.value ?? parameter.defaultValue
            } set: { value in
                guard let choice = parameter.choices.first(where: { $0.value == value }) else { return }
                onChange(choice)
            }
        ) {
            ForEach(parameter.choices, id: \.value) { choice in
                Text(verbatim: choice.name).tag(choice.value)
            }
        } label: {
            Text(verbatim: parameter.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .pickerStyle(.menu)
        .controlSize(.mini)
    }
}
