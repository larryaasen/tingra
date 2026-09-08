//
//  FadeToBlackButton.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The **Fade to Black** control, in the main window's toolbar beside
/// ``StreamButton`` and ``RecordButton``: one latching button that takes the
/// whole program off air — picture *and* sound together — and brings it back
/// (GLOSSARY.md, "Fade to black").
///
/// It sat at the trailing end of the transition panel until 2026-09-07,
/// where it was the one control on that row that is **not a transition**: a
/// transition is the move from one shot to the next, where FTB is a master
/// stage that holds across shot switches. The toolbar is where the window's
/// other controls that change what viewers get already live — Start
/// Streaming and Record — and where a button an operator reaches for under
/// pressure is always on screen rather than scrolled away with the panels.
///
/// It stays enabled when the preset has no shots — the operator must always
/// be able to take the program down. **While faded, the symbol is a filled
/// red frame** — a black frame on air, lit the way a latched FTB is on a
/// hardware panel — and the word beside it says what the next click does,
/// so the state and the action never read as one. The color is applied to
/// the image itself rather than through `tint`, because a toolbar draws its
/// items' labels in its own monochrome style and a tint never reaches the
/// glyph (the ``RecordButton`` rule). The transition panel's hint that
/// viewers see and hear nothing went with the move: the program monitor's
/// own badge already says it (``ContentView/fadedToBlackLabel``).
///
/// ⇧⌘B (``ProductionShortcut/fadeToBlack``) binds here, so the shortcut moved
/// with the button, and the `tap` keeps the name it has always reported
/// (`fadeToBlack.button`), so a log reader sees one session whichever
/// surface the fade came from.
struct FadeToBlackButton: View {
    /// The engine model the control drives.
    let model: EngineModel

    var body: some View {
        Button {
            model.eventBus.tap(
                "fadeToBlack.button",
                domain: .composition,
                params: ["state": .string(model.isFadedToBlack ? "clear" : "black")]
            )
            model.setFadeToBlack(!model.isFadedToBlack)
        } label: {
            if model.isFadedToBlack {
                Label {
                    Text("Fade Up", comment: "Toolbar button that brings the program back from black")
                } icon: {
                    Image(systemName: "rectangle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                Label {
                    ProductionShortcut.fadeToBlack.name
                } icon: {
                    Image(systemName: "rectangle")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .keyboardShortcut(ProductionShortcut.fadeToBlack.shortcut)
        .help(
            Text(
                "Take the whole program — picture and sound — off air, or bring it back",
                comment: "Tooltip on the Fade to Black toolbar button"
            )
        )
    }
}
