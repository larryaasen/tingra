//
//  CompactPresetsMenu.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraHost

/// The compact window's **Presets** pull-down, beside the camera picker: the
/// compact window has no sidebar, so this is where its presets live.
///
/// It lists what the menu bar's Presets menu lists (``PresetMenuItems``:
/// Save Preset…, one item per preset recalling it, Default Preset), then a
/// **Manage Presets** submenu holding, per preset, the items the standard
/// window's sidebar row offers on a right-click (``PresetContextMenu``) — so
/// nothing a preset can do is out of reach in either window.
struct CompactPresetsMenu: View {
    /// The shared model holding the presets.
    @Environment(HardwareModel.self) private var model

    /// The window's camera session, which a recalled preset goes to.
    @Environment(CameraSession.self) private var session

    /// Opens a preset dialog over the window.
    @Environment(\.presetDialogPresenter) private var presetDialogPresenter

    /// The pull-down button.
    var body: some View {
        Menu {
            PresetMenuItems(model: model, session: session, presenter: presetDialogPresenter, tapKind: "pullDownItem")

            if !model.presets.isEmpty {
                Divider()

                Menu {
                    ForEach(model.presets.presets) { preset in
                        Menu {
                            PresetContextMenu(
                                preset: preset,
                                isAvailable: model.camera(for: preset) != nil,
                                tapKind: "manageMenuItem"
                            )
                        } label: {
                            Text(verbatim: preset.name)
                        }
                    }
                } label: {
                    Text(
                        "Manage Presets",
                        comment: "Compact window Presets pull-down submenu: update, rename, or delete each preset"
                    )
                }
            }
        } label: {
            Text(
                "Presets", comment: "Title of the Presets menu and the sidebar section listing the saved camera presets"
            )
        }
        .fixedSize()
    }
}
