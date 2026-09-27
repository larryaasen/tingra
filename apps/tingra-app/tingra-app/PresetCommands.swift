//
//  PresetCommands.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// The **Presets** menu: an **Add Preset** item, then one item per preset in
/// the project, in sidebar order, switching to that preset, with the active
/// one checked — the ``ShotCommands`` menu one level up the
/// `project > preset > shot` hierarchy.
///
/// Add Preset leads for the Shots menu's reason: a menu named for a thing is
/// where a Mac user looks to make one, and the list below it grows, so an
/// item that moved as presets were added would be one to hunt for. It is a
/// plain item rather than a submenu, like the sidebar's Presets header
/// context menu, since a preset has no kinds to choose among, and it reports
/// its own `tap` (`presetsMenuAdd.menuItem`) so a log reader can tell a
/// preset added here from one added in the sidebar.
///
/// **Each preset is a checkmark toggle**, the way a radio group reads in a Mac
/// menu (``ProgramCommands``'s Size and Frame Rate): the check is the
/// sidebar's checkmark on the active preset, never a tally lamp, because a
/// preset is not on a bus. Choosing the checked item asks to turn it off,
/// which a radio group ignores. Switching **never interrupts what is on
/// program** (GLOSSARY.md, "Preset"), so the items are safe while live and
/// are never disabled.
///
/// **No keyboard shortcuts.** ⌘1–⌘9 stage shots (``ProductionShortcut``),
/// and the shortcuts are taken from switcher consoles rather than invented;
/// a preset is switched once per segment, not cut to, so it does not earn a
/// key of its own. Every preset is listed, so each one is still a click away
/// here when the sidebar is hidden.
///
/// It sits between the Program menu and the Shots menu: the signal path's
/// order, the sidebar's rule — presets hold shots.
struct PresetCommands: Commands {
    /// The engine model the items add and switch through, and report their
    /// `tap` to.
    let model: EngineModel

    /// The menu.
    var body: some Commands {
        CommandMenu(Text("Presets", comment: "Title of the Presets menu, listing the project's presets")) {
            Button {
                model.eventBus.tap("presetsMenuAdd.menuItem", domain: .composition)
                model.addPreset()
            } label: {
                Text("Add Preset", comment: "Button adding a new empty preset to the project")
            }

            Divider()

            if model.presets.isEmpty {
                Text("No Presets", comment: "Placeholder item in the Presets menu when the project has none")
            } else {
                ForEach(model.presets) { preset in
                    Toggle(isOn: activeBinding(preset)) {
                        Text(verbatim: preset.name)
                    }
                }
            }
        }
    }

    /// A preset's checkmark: on while it is the active preset; setting it
    /// switches to that preset. Clicking the checked item asks to turn it
    /// off, which a radio group ignores.
    ///
    /// - Parameter preset: The item's preset.
    /// - Returns: The binding.
    private func activeBinding(_ preset: Preset) -> Binding<Bool> {
        Binding {
            model.activePresetID == preset.id
        } set: { isOn in
            guard isOn else { return }
            model.eventBus.tap(
                "preset.menuItem",
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
            )
            Task { await model.switchPreset(to: preset.id) }
        }
    }
}
