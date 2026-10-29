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
/// preset recalling it, then a **Default Preset** submenu choosing the
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

    /// The menu.
    var body: some Commands {
        CommandMenu(
            Text(
                "Presets", comment: "Title of the Presets menu and the sidebar section listing the saved camera presets"
            )
        ) {
            Button {
                model.recordPresetTap("cameraPresetSave.menuItem")
                presetDialogPresenter?.present(.save, model: model)
            } label: {
                Text("Save Preset…", comment: "Command saving the selected camera's settings as a new preset")
            }
            .disabled(presetDialogPresenter == nil || !model.canSavePreset)

            Divider()

            if model.presets.isEmpty {
                Text(
                    "No Presets",
                    comment: "Placeholder in the sidebar and the Presets menu when no camera preset has been saved")
            } else {
                ForEach(model.presets.presets) { preset in
                    Button {
                        model.recordPresetTap("cameraPreset.menuItem", preset: preset)
                        model.recallPreset(preset.id)
                    } label: {
                        Text(verbatim: preset.name)
                    }
                    .disabled(model.camera(for: preset) == nil)
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
    }

    /// The Default Preset submenu's selection: the default preset; choosing
    /// another makes it the default, recording the tap first.
    private var defaultBinding: Binding<CameraPreset.ID?> {
        Binding {
            model.presets.defaultPresetID
        } set: { id in
            guard let id, let preset = model.presets.preset(withID: id) else { return }
            model.recordPresetTap("cameraPresetDefault.menuItem", preset: preset)
            model.makeDefaultPreset(id)
        }
    }
}
