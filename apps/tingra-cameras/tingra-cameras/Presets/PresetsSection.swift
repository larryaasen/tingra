//
//  PresetsSection.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraHost

/// The sidebar's Presets section: one row per saved camera preset, above the
/// cameras, with the default marked — the main Tingra app's Presets section,
/// for camera settings (docs/UVC.md, "Camera presets").
///
/// Clicking a row **recalls** the preset: its camera is selected and given
/// the preset's settings. A preset whose camera is not connected is dimmed
/// and cannot be recalled, but can still be managed. **Saving** a preset is
/// the section header's context menu and the Presets menu, as adding a
/// preset is in the main app; each row's context menu recalls, makes the
/// default, updates, renames, and deletes it. The section collapses like
/// every sidebar section (``SidebarView``), over the binding it is given.
struct PresetsSection: View {
    /// The shared model holding the presets.
    @Environment(HardwareModel.self) private var model

    /// The window's camera session, whose camera Save Preset… saves.
    @Environment(CameraSession.self) private var session

    /// Opens a preset dialog over the window.
    @Environment(\.presetDialogPresenter) private var presetDialogPresenter

    /// Whether the section is open — the sidebar's persisted expansion.
    @Binding var isExpanded: Bool

    /// The section.
    var body: some View {
        Section(isExpanded: $isExpanded) {
            if model.presets.isEmpty {
                Text(
                    "No Presets",
                    comment: "Placeholder in the sidebar and the Presets menu when no camera preset has been saved"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ForEach(model.presets.presets) { preset in
                    PresetRow(preset: preset)
                }
            }
        } header: {
            Text(
                "Presets", comment: "Title of the Presets menu and the sidebar section listing the saved camera presets"
            )
            // The whole header row answers the right-click, not just the word.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .contextMenu {
                Button {
                    model.recordPresetTap("cameraPresetSave.menu")
                    presetDialogPresenter?.present(.save, model: model)
                } label: {
                    Text("Save Preset…", comment: "Command saving the selected camera's settings as a new preset")
                }
                .disabled(!session.canSavePreset)
            }
        }
    }
}

/// One preset row: the preset's name over its camera's name, a trailing
/// Default label on the default preset, recalling the preset in the window
/// when clicked.
private struct PresetRow: View {
    /// The shared model holding the presets.
    @Environment(HardwareModel.self) private var model

    /// The window's camera session, which a recalled preset goes to.
    @Environment(CameraSession.self) private var session

    /// Opens a preset dialog over the window.
    @Environment(\.presetDialogPresenter) private var presetDialogPresenter

    /// The row's preset.
    let preset: CameraPreset

    /// The row.
    var body: some View {
        let isAvailable = model.camera(for: preset) != nil
        Button {
            model.recordPresetTap("cameraPreset.row", preset: preset)
            session.recallPreset(preset.id)
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(verbatim: preset.name)
                        // A camera's name is a proper noun from the system.
                        Text(verbatim: preset.cameraName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
                Spacer(minLength: 0)
                if model.presets.isDefault(preset.id) {
                    Text("Default", comment: "Sidebar label marking the camera preset applied at launch")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(
            isAvailable
                ? Text("Recall this preset", comment: "Tooltip on a sidebar camera preset row")
                : Text(
                    "\(preset.cameraName) is not connected",
                    comment: "Tooltip on a camera preset whose camera is unplugged; the placeholder is its name"
                )
        )
        .contextMenu {
            PresetContextMenu(preset: preset, isAvailable: isAvailable, tapKind: "menu")
        }
    }
}

/// A preset row's context menu: recall it, make it the default, update it
/// with the camera's current settings, rename it, and delete it. The compact
/// window's Presets pull-down shows the same items as one submenu per preset
/// (``CompactPresetsMenu``).
struct PresetContextMenu: View {
    /// The shared model holding the presets.
    @Environment(HardwareModel.self) private var model

    /// The window's camera session: the camera a recalled preset goes to and
    /// whose settings Update with Current Settings takes.
    @Environment(CameraSession.self) private var session

    /// Opens a preset dialog over the window.
    @Environment(\.presetDialogPresenter) private var presetDialogPresenter

    /// The preset the menu was opened on.
    let preset: CameraPreset

    /// Whether the preset's camera is connected.
    let isAvailable: Bool

    /// The kind of control the items' taps are reported as, the last part of
    /// each tap name: `menu` for the row's context menu, `pullDownItem` in
    /// the compact window (EVENTS.md, "The `tap` convention").
    let tapKind: String

    /// The items.
    var body: some View {
        Button {
            model.recordPresetTap("cameraPresetRecall.\(tapKind)", preset: preset)
            session.recallPreset(preset.id)
        } label: {
            Text("Recall", comment: "Camera preset context menu: apply this preset to its camera")
        }
        .disabled(!isAvailable)

        Button {
            model.recordPresetTap("cameraPresetDefault.\(tapKind)", preset: preset)
            model.makeDefaultPreset(preset.id)
        } label: {
            Text("Set as Default", comment: "Camera preset context menu: apply this preset at launch")
        }
        .disabled(model.presets.isDefault(preset.id))

        Button {
            model.recordPresetTap("cameraPresetUpdate.\(tapKind)", preset: preset)
            session.updatePreset(preset.id)
        } label: {
            Text(
                "Update with Current Settings",
                comment: "Camera preset context menu: replace this preset's settings with the camera's current ones"
            )
        }
        .disabled(!session.canUpdatePreset(preset))

        Divider()

        Button {
            model.recordPresetTap("cameraPresetRename.\(tapKind)", preset: preset)
            presetDialogPresenter?.present(.rename(preset), model: model)
        } label: {
            Text("Rename…", comment: "Camera preset context menu: rename this preset")
        }

        Button(role: .destructive) {
            model.recordPresetTap("cameraPresetDelete.\(tapKind)", preset: preset)
            presetDialogPresenter?.present(.delete(preset), model: model)
        } label: {
            Text("Delete Preset…", comment: "Camera preset context menu: delete this preset, after confirming")
        }
    }
}
