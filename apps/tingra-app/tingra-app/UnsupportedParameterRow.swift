//
//  UnsupportedParameterRow.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The row a parameters editor draws for a declared parameter whose kind this
/// build of the app does not know: the parameter's name, and a note that a
/// newer Tingra is needed to edit it.
///
/// `Parameter.Kind` is an open enum in the resilient kit (PLUGINS.md,
/// Decision 22), so a host-tier plug-in bundle built against a later kit can
/// declare a kind added after this app was built. Drawing nothing would hide
/// the parameter without a word; this row says it is there and why it cannot
/// be edited. Shared by the layer chain, the audio chain, and the input
/// settings so the three cannot drift.
struct UnsupportedParameterRow: View {
    /// The parameter the row names.
    let parameter: Parameter

    var body: some View {
        HStack(spacing: 4) {
            Text(parameter.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Needs a newer version of Tingra")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .help(
            Text(
                "This plug-in declares a kind of setting this version of Tingra can't edit. Update Tingra to change it."
            ))
    }
}
