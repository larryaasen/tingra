//
//  ShotCommands.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// The **Shots** menu: one item per shot in the active preset, in switcher
/// order, staging that shot on preview — the first nine under ⌘1–⌘9
/// (``ProductionShortcut/stageShot``).
///
/// **The ⌘1–⌘9 shortcuts moved here from the preview row's buttons**, and
/// the move is a change of the rule the shortcuts were placed under. The rule
/// was "shortcuts live on the controls, not on menu items", for a reason that
/// still holds where it applies: a shortcut on a control inherits the
/// control's disabled and live state, which is why Cut, Take, and Fade to
/// Black keep theirs on the ``TransitionPanel``'s buttons. But the preview
/// row is now hidden by default (``SwitcherRowsPreferences``), and a
/// shortcut on a control that is not on screen is a shortcut that does not
/// work — so staging by number needs a home that is always there, and on a
/// Mac that home is the menu bar. A menu is also where an operator looks
/// for a key they half remember, which no row of buttons is. The items
/// carry the shots' own names, the way the Window menu lists windows, so the
/// menu doubles as the answer to "which shot is ⌘4".
///
/// Every shot is listed, not only the first nine: a tenth shot has no key
/// but is still one click away here when the sidebar is hidden.
struct ShotCommands: Commands {
    /// The engine model the items stage through, and report their `tap` to.
    let model: EngineModel

    /// The menu.
    var body: some Commands {
        CommandMenu(Text("Shots", comment: "Title of the Shots menu, listing the active preset's shots")) {
            if model.shots.isEmpty {
                Text("No Shots", comment: "Placeholder item in the Shots menu when the active preset has none")
            } else {
                ForEach(Array(model.shots.enumerated()), id: \.element.id) { index, shot in
                    Button {
                        model.eventBus.tap(
                            "shot.menuItem",
                            domain: .composition,
                            params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
                        )
                        model.setPreview(shot.id)
                    } label: {
                        Text(verbatim: shot.name)
                    }
                    // ⌘1…⌘9 by position; the optional overload leaves a
                    // tenth shot unbound rather than needing a branch here.
                    .keyboardShortcut(ProductionShortcut.stageShotShortcut(forIndex: index))
                }
            }
        }
    }
}
