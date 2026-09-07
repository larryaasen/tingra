//
//  PresetContextMenu.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// Which surface a preset's context menu is attached to — today only the
/// sidebar's preset rows.
///
/// The menu is one view (``PresetContextMenu``), and this is what says which
/// `tap` names and which reorder words a given attachment carries: two
/// controls performing one action report separately (EVENTS.md, "The `tap`
/// convention"), and a vertical list moves things up and down where a
/// horizontal row would move them left and right. It had two cases while the
/// main window carried a preset switcher row beside the sidebar; that row was
/// removed 2026-09-06 as a repeat of the sidebar's list, and the seam stays
/// so the next surface that lists presets attaches the same menu the same
/// way.
enum PresetMenuSurface: Sendable, CaseIterable {
    /// The Presets section of the main window's sidebar.
    case sidebar

    /// The actions the menu and its rename dialog report.
    enum Action: Sendable, CaseIterable {
        /// The Duplicate item.
        case duplicate

        /// The Rename… item, which opens the dialog.
        case rename

        /// The item moving the preset one place earlier: Move Up in the
        /// sidebar.
        case moveEarlier

        /// The item moving the preset one place later: Move Down in the
        /// sidebar.
        case moveLater

        /// The Remove Preset item.
        case remove

        /// The rename dialog's confirm button.
        case renameConfirm

        /// The rename dialog's cancel button.
        case renameCancel
    }

    /// The `tap` name one of the menu's actions reports from this surface.
    ///
    /// The sidebar's are prefixed `sidebarPreset`, on the pattern its rows
    /// already follow (`sidebarPreset.row`). The move items are named for the
    /// direction the operator sees, since that is what a log reader replaying
    /// a session would look for.
    ///
    /// - Parameter action: The action reporting.
    /// - Returns: The tap name.
    func tapName(for action: Action) -> String {
        let prefix =
            switch self {
            case .sidebar: "sidebarPreset"
            }
        switch action {
        case .duplicate:
            return "\(prefix)Duplicate.menu"
        case .rename:
            return "\(prefix)Rename.menu"
        case .moveEarlier:
            return "\(prefix)MoveUp.menu"
        case .moveLater:
            return "\(prefix)MoveDown.menu"
        case .remove:
            return "\(prefix)Remove.menu"
        case .renameConfirm:
            return "\(prefix)RenameConfirm.button"
        case .renameCancel:
            return "\(prefix)RenameCancel.button"
        }
    }
}

/// One preset's context menu: duplicate, rename, reorder, and remove that
/// preset — the shot commands, one level up (ARCHITECTURE.md, "Multiple
/// presets in the UI", "Shot and preset reordering").
///
/// Attached to the sidebar's preset rows — and to any surface that lists
/// presets, so right-clicking a preset offers the same commands wherever it
/// is listed; ``PresetMenuSurface`` supplies the surface's `tap` names and
/// the direction words its reorder items use. Reorder matters: the app adopts
/// the first preset at launch, so moving one to the front makes it the next
/// session's default. Remove is immediate like a shot's, but disabled on the
/// last remaining preset: a project always holds at least one.
///
/// The rename **dialog** is the caller's (``PresetRenameDialog``): a context
/// menu cannot present an alert from inside itself, so Rename… hands the
/// preset back through `onRename` and the view that owns the menu opens the
/// dialog over its own content.
struct PresetContextMenu: View {
    /// The engine model the commands act on.
    let model: EngineModel

    /// The preset the menu was opened on.
    let preset: Preset

    /// Which surface the menu is attached to.
    let surface: PresetMenuSurface

    /// What Rename… does after its `tap`: the caller opens its rename dialog
    /// over this preset.
    let onRename: (Preset) -> Void

    /// The five items, in the order the shot menu uses.
    var body: some View {
        let index = model.presets.firstIndex { $0.id == preset.id }

        Button {
            model.eventBus.tap(
                surface.tapName(for: .duplicate),
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
            )
            model.duplicatePreset(preset.id)
        } label: {
            Text("Duplicate", comment: "Context menu: duplicate this shot or preset")
        }

        Button {
            model.eventBus.tap(
                surface.tapName(for: .rename),
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
            )
            onRename(preset)
        } label: {
            Text("Rename…", comment: "Context menu: rename this shot or preset")
        }

        Divider()

        Button {
            guard let index else { return }
            model.eventBus.tap(
                surface.tapName(for: .moveEarlier),
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "index": .int(index)]
            )
            model.movePreset(preset.id, to: index - 1)
        } label: {
            switch surface {
            case .sidebar:
                Text("Move Up", comment: "Sidebar preset context menu: move this preset earlier in the project order")
            }
        }
        .disabled((index ?? 0) <= 0)

        Button {
            guard let index else { return }
            model.eventBus.tap(
                surface.tapName(for: .moveLater),
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "index": .int(index)]
            )
            model.movePreset(preset.id, to: index + 1)
        } label: {
            switch surface {
            case .sidebar:
                Text("Move Down", comment: "Sidebar preset context menu: move this preset later in the project order")
            }
        }
        .disabled(index.map { $0 >= model.presets.count - 1 } ?? true)

        Divider()

        Button(role: .destructive) {
            model.eventBus.tap(
                surface.tapName(for: .remove),
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
            )
            Task { await model.removePreset(preset.id) }
        } label: {
            Text("Remove Preset", comment: "Preset context menu: remove this preset from the project")
        }
        .disabled(model.presets.count == 1)
    }
}

/// The preset rename dialog, presented over whichever view owns the menu that
/// opened it.
///
/// A modifier rather than a view so the two surfaces carrying
/// ``PresetContextMenu`` present one dialog with one pair of `tap` names per
/// surface, and so each keeps its own subject: which preset is being renamed
/// is transient session state that belongs to the view showing the dialog.
/// The `isPresented` binding derives from the subject and clears it on
/// dismissal, so Escape and Cancel both leave nothing pending.
struct PresetRenameDialog: ViewModifier {
    /// The engine model the rename is applied to.
    let model: EngineModel

    /// Which surface opened the dialog, for its buttons' `tap` names.
    let surface: PresetMenuSurface

    /// The preset being renamed, or `nil` while the dialog is closed.
    @Binding var preset: Preset?

    /// The dialog's working text, prefilled by the caller with the preset's
    /// current name.
    @Binding var text: String

    /// Whether the dialog is up.
    private var isPresented: Binding<Bool> {
        Binding {
            preset != nil
        } set: { presented in
            if !presented { preset = nil }
        }
    }

    func body(content: Content) -> some View {
        content.alert(
            Text("Rename Preset", comment: "Rename preset dialog title"),
            isPresented: isPresented,
            presenting: preset
        ) { preset in
            TextField(text: $text) {
                Text("Name", comment: "Name text field label — for a shot, a preset, or a destination")
            }
            Button {
                model.eventBus.tap(
                    surface.tapName(for: .renameConfirm),
                    domain: .composition,
                    params: ["preset": .string(preset.id.rawValue), "name": .string(text)]
                )
                model.renamePreset(preset.id, to: text)
            } label: {
                Text("Rename", comment: "Rename dialog confirm button, for a shot or a preset")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    surface.tapName(for: .renameCancel),
                    domain: .composition,
                    params: ["preset": .string(preset.id.rawValue)]
                )
            } label: {
                Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
            }
        }
    }
}

extension View {
    /// Attaches the preset rename dialog (``PresetRenameDialog``).
    ///
    /// - Parameters:
    ///   - model: The engine model the rename is applied to.
    ///   - surface: Which surface opened it, for its `tap` names.
    ///   - preset: The preset being renamed, or `nil` while closed.
    ///   - text: The dialog's working text.
    /// - Returns: The view with the dialog attached.
    func presetRenameDialog(
        model: EngineModel,
        surface: PresetMenuSurface,
        preset: Binding<Preset?>,
        text: Binding<String>
    ) -> some View {
        modifier(PresetRenameDialog(model: model, surface: surface, preset: preset, text: text))
    }
}
