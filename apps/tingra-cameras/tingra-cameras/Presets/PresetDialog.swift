//
//  PresetDialog.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraHost

/// A camera preset dialog a window can show: naming a new preset, renaming
/// one, or confirming a deletion.
enum PresetDialog: Equatable {
    /// Save Preset: name a new preset holding the selected camera's settings.
    case save
    /// Rename Preset: a new name for a preset.
    case rename(CameraPreset)
    /// Delete Preset: confirm deleting a preset, which cannot be undone.
    case delete(CameraPreset)
}

/// Which preset dialog one window is showing, and the dialog's working
/// name — the window's transient state, shared by the dialogs and the
/// controls that open them.
///
/// A class so the sidebar and the Presets menu reach the window's one
/// instance through the environment and the focused scene value; its
/// identity never changes, so publishing it there invalidates nothing.
@MainActor
@Observable
final class PresetDialogPresenter {
    /// The dialog showing, or nil.
    var dialog: PresetDialog?

    /// The Save and Rename dialogs' working text.
    var name = ""

    /// Shows a dialog, prefilling the name field for the ones that take a
    /// name: the next numbered name for a new preset, the current name for a
    /// rename.
    ///
    /// - Parameters:
    ///   - dialog: The dialog to show.
    ///   - model: The shared model, for the suggested name.
    func present(_ dialog: PresetDialog, model: HardwareModel) {
        switch dialog {
        case .save:
            name = model.suggestedPresetName
        case .rename(let preset):
            name = preset.name
        case .delete:
            break
        }
        self.dialog = dialog
    }
}

extension EnvironmentValues {
    /// The window's preset dialog presenter — how the sidebar's Presets
    /// section opens a dialog. Nil outside a window that hosts the dialogs
    /// (``PresetDialogs``).
    @Entry var presetDialogPresenter: PresetDialogPresenter?
}

extension FocusedValues {
    /// The key window's preset dialog presenter — how the Presets menu opens
    /// a dialog over the window the operator is working in and no other.
    @Entry var presetDialogPresenter: PresetDialogPresenter?
}

/// The camera preset dialogs, presented over a window's content.
///
/// One per window, owned by the window's root view rather than the sidebar,
/// so a dialog still appears with the sidebar collapsed, and opened from
/// either the sidebar (through the environment) or the Presets menu (through
/// the focused scene value). Which dialog is up is the window's transient
/// state (``PresetDialogPresenter``); the dialogs' bindings derive from it
/// and clear it on dismissal,
/// so Escape and Cancel both leave nothing pending.
struct PresetDialogs: ViewModifier {
    /// The shared model the dialogs act on.
    let model: HardwareModel

    /// The window's camera session, whose camera Save Preset saves.
    let session: CameraSession

    /// The window's dialog state, owned here for the window's lifetime.
    @State private var presenter = PresetDialogPresenter()

    /// Attaches the three dialogs and publishes the presenter that opens
    /// them.
    func body(content: Content) -> some View {
        @Bindable var presenter = presenter
        return
            content
            .environment(\.presetDialogPresenter, presenter)
            .focusedSceneValue(\.presetDialogPresenter, presenter)
            .alert(
                Text("Save Preset", comment: "Title of the dialog naming a new camera preset"),
                isPresented: isPresented { $0 == .save }
            ) {
                TextField(text: $presenter.name) {
                    Text("Name", comment: "Name text field label in the camera preset dialogs")
                }
                Button {
                    model.recordPresetTap("cameraPresetSaveConfirm.button")
                    session.savePreset(named: presenter.name)
                } label: {
                    Text("Save", comment: "Save Preset dialog confirm button")
                }
                Button(role: .cancel) {
                    model.recordPresetTap("cameraPresetSaveCancel.button")
                } label: {
                    Text("Cancel", comment: "Camera preset dialog cancel button")
                }
            } message: {
                if let camera = session.selectedCamera {
                    Text(
                        "The preset keeps the current settings of \(camera.name).",
                        comment: "Save Preset dialog message; the placeholder is the camera's name"
                    )
                }
            }
            .alert(
                Text("Rename Preset", comment: "Title of the dialog renaming a camera preset"),
                isPresented: isPresented { if case .rename = $0 { true } else { false } },
                presenting: renaming
            ) { preset in
                TextField(text: $presenter.name) {
                    Text("Name", comment: "Name text field label in the camera preset dialogs")
                }
                Button {
                    model.recordPresetTap("cameraPresetRenameConfirm.button", preset: preset)
                    model.renamePreset(preset.id, to: presenter.name)
                } label: {
                    Text("Rename", comment: "Rename Preset dialog confirm button")
                }
                Button(role: .cancel) {
                    model.recordPresetTap("cameraPresetRenameCancel.button", preset: preset)
                } label: {
                    Text("Cancel", comment: "Camera preset dialog cancel button")
                }
            }
            .alert(
                Text("Delete Preset", comment: "Title of the dialog confirming a camera preset's deletion"),
                isPresented: isPresented { if case .delete = $0 { true } else { false } },
                presenting: deleting
            ) { preset in
                Button(role: .destructive) {
                    model.recordPresetTap("cameraPresetDeleteConfirm.button", preset: preset)
                    model.deletePreset(preset.id)
                } label: {
                    Text("Delete", comment: "Delete Preset dialog confirm button")
                }
                Button(role: .cancel) {
                    model.recordPresetTap("cameraPresetDeleteCancel.button", preset: preset)
                } label: {
                    Text("Cancel", comment: "Camera preset dialog cancel button")
                }
            } message: { preset in
                Text(
                    "\(preset.name) will be deleted. This cannot be undone.",
                    comment: "Delete Preset dialog message; the placeholder is the preset's name"
                )
            }
    }

    /// The preset being renamed, or nil.
    private var renaming: CameraPreset? {
        if case .rename(let preset) = presenter.dialog { preset } else { nil }
    }

    /// The preset whose deletion is being confirmed, or nil.
    private var deleting: CameraPreset? {
        if case .delete(let preset) = presenter.dialog { preset } else { nil }
    }

    /// Whether one kind of dialog is up; setting it false dismisses it.
    ///
    /// - Parameter matches: Whether a dialog is the kind in question.
    /// - Returns: The binding.
    private func isPresented(_ matches: @escaping (PresetDialog) -> Bool) -> Binding<Bool> {
        Binding {
            presenter.dialog.map(matches) ?? false
        } set: { presented in
            if !presented { presenter.dialog = nil }
        }
    }
}

extension View {
    /// Hosts the camera preset dialogs over this view (``PresetDialogs``).
    ///
    /// - Parameters:
    ///   - model: The shared model the dialogs act on.
    ///   - session: The window's camera session, whose camera Save Preset
    ///     saves.
    /// - Returns: The view with the dialogs attached.
    func presetDialogs(model: HardwareModel, session: CameraSession) -> some View {
        modifier(PresetDialogs(model: model, session: session))
    }
}
