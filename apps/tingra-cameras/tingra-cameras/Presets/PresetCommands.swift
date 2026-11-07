//
//  PresetCommands.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraHost

/// The **Presets** menu: **Save Preset…**, then one item per saved camera
/// preset recalling it in the key window, then a **Default Preset** submenu choosing the
/// preset applied at launch — the main Tingra app's Presets menu, for
/// camera settings.
///
/// Save Preset… leads because a menu named for a thing is where a Mac user
/// looks to make one, and the list below it grows. A preset whose camera is
/// not connected is listed but disabled. Save Preset… opens its dialog over
/// the key window (the focused scene value ``PresetDialogs`` publishes), so
/// it is disabled with no window open.
struct PresetCommands: Commands {
    /// The shared model holding the presets.
    let model: HardwareModel

    /// Opens a preset dialog over the key window, or nil with none open.
    @FocusedValue(\.presetDialogPresenter) private var presetDialogPresenter

    /// The key window's camera session, which a recalled preset goes to, or
    /// nil with none open.
    @FocusedValue(\.cameraSession) private var session

    /// The menu.
    var body: some Commands {
        CommandMenu(
            Text(
                "Presets", comment: "Title of the Presets menu and the sidebar section listing the saved camera presets"
            )
        ) {
            PresetMenuItems(model: model, session: session, presenter: presetDialogPresenter, tapKind: "menuItem")
        }
    }
}

/// The Presets menu's items — **Save Preset…**, one item per saved preset
/// recalling it, and the **Default Preset** submenu — shared by the menu
/// bar's Presets menu (``PresetCommands``) and the compact window's Presets
/// pull-down (``CompactPresetsMenu``), so the two can never list different
/// things.
struct PresetMenuItems: View {
    /// The shared model holding the presets.
    let model: HardwareModel

    /// The camera session of the window the items act for: the camera Save
    /// Preset… saves and a recalled preset goes to. Nil with no window, which
    /// disables both.
    let session: CameraSession?

    /// Opens a preset dialog over the window the items act for, or nil with
    /// none, which disables Save Preset….
    let presenter: PresetDialogPresenter?

    /// The kind of control the items' taps are reported as, the last part of
    /// each tap name: `menuItem` in the menu bar, `pullDownItem` in the
    /// compact window (EVENTS.md, "The `tap` convention").
    let tapKind: String

    /// The items.
    var body: some View {
        Button {
            model.recordPresetTap("cameraPresetSave.\(tapKind)")
            presenter?.present(.save, model: model)
        } label: {
            Text("Save Preset…", comment: "Command saving the selected camera's settings as a new preset")
        }
        .disabled(presenter == nil || !(session?.canSavePreset ?? false))

        Divider()

        if model.presets.isEmpty {
            Text(
                "No Presets",
                comment: "Placeholder in the sidebar and the Presets menu when no camera preset has been saved")
        } else {
            ForEach(model.presets.presets) { preset in
                Button {
                    model.recordPresetTap("cameraPreset.\(tapKind)", preset: preset)
                    session?.recallPreset(preset.id)
                } label: {
                    Text(verbatim: preset.name)
                }
                .disabled(session == nil || model.camera(for: preset) == nil)
            }

            Divider()

            Picker(selection: defaultBinding) {
                ForEach(model.presets.presets) { preset in
                    Text(verbatim: preset.name).tag(Optional(preset.id))
                }
            } label: {
                Text("Default Preset", comment: "Presets menu submenu choosing the preset applied at launch")
            }
        }
    }

    /// The Default Preset submenu's selection: the default preset; choosing
    /// another makes it the default, recording the tap first.
    private var defaultBinding: Binding<CameraPreset.ID?> {
        Binding {
            model.presets.defaultPresetID
        } set: { id in
            guard let id, let preset = model.presets.preset(withID: id) else { return }
            model.recordPresetTap("cameraPresetDefault.\(tapKind)", preset: preset)
            model.makeDefaultPreset(id)
        }
    }
}
