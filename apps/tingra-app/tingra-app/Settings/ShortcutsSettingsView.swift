//
//  ShortcutsSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The Shortcuts settings pane: what the production keyboard shortcuts are
/// and what each one does.
///
/// **Read-only, deliberately.** The pane lists the bindings rather than
/// letting the operator rebind them, because the assignments are the ones the
/// professional switchers already share (see ``ProductionShortcut``) and
/// there is nothing yet to reconcile a custom set against — a rebinding UI
/// that has to persist, validate for conflicts, and reset to defaults is its
/// own feature, and shipping the listing first is what makes the shortcuts
/// discoverable at all.
///
/// It reads its rows straight from ``ProductionShortcut``, the same list the
/// controls bind, so a shortcut printed here and a shortcut that works cannot
/// disagree.
struct ShortcutsSettingsView: View {
    /// **One group, no headings, no footnote.** The shortcuts are six lines an
    /// operator reads top to bottom; splitting them into "switching" and
    /// "output", or into the five common ones and the take, would make the
    /// reader decide which heading their question lives under before they can
    /// scan for it. Where the assignments came from is worth recording — it is
    /// why the take is ⌘Return and not ⌘T (see ``ProductionShortcut``) — but
    /// it is provenance for whoever maintains the list, not something an
    /// operator looking up a key needs read to them.
    ///
    /// The rows come from `ProductionShortcut.allCases`, so the pane lists
    /// every shortcut the app binds by construction — a seventh cannot be
    /// added and forgotten here.
    var body: some View {
        Form {
            Section {
                ForEach(ProductionShortcut.allCases, id: \.self) { shortcut in
                    ShortcutRow(shortcut: shortcut)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One row of the Shortcuts pane: the action's name and what it does, with
/// its key combination on the trailing edge.
struct ShortcutRow: View {
    /// The shortcut the row describes.
    let shortcut: ProductionShortcut

    /// The row.
    var body: some View {
        LabeledContent {
            Text(verbatim: shortcut.symbol)
                .foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                shortcut.name
                shortcut.detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
