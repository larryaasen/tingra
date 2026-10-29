//
//  EffectParameterToggle.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The control every generic parameter editor draws for a toggle parameter
/// (`Parameter.Kind.toggle`, docs/UVC.md): the parameter's name beside a
/// small switch, shared by the input settings popover and both effect chain
/// editors so they cannot drift.
///
/// A flip is one discrete change, so the caller reports its `tap` and
/// applies the value in `onChange` — no gesture to coalesce, unlike a
/// slider or a color well.
struct EffectParameterToggle: View {
    /// The parameter the switch edits, for its name.
    let parameter: Parameter

    /// Whether the parameter is on.
    let isOn: Bool

    /// Called with the new state when the operator flips the switch.
    let onChange: (Bool) -> Void

    /// The name, then the switch.
    var body: some View {
        Toggle(
            isOn: Binding {
                isOn
            } set: {
                onChange($0)
            }
        ) {
            Text(parameter.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}
