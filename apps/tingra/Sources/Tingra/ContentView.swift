//
//  ContentView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// The main window: the program preview above the shot switcher, the
/// layer-tree editor, and the input pickers.
///
/// The pickers pick one camera and one display; the switcher takes the
/// chosen shot to program — a cut, or a dissolve when the switcher's
/// transition toggle is on (GLOSSARY.md, "Transition") — and manages the
/// preset's shots: an Add Shot button appends a new empty shot, and each
/// shot button's context menu duplicates, renames, or removes that shot
/// (ARCHITECTURE.md, "Shot management"); the editor
/// (``LayerTreeEditorView``) edits the selected shot's layer tree live.
/// This is the step-7 shape — the remaining production surface (multiple
/// presets, the mixer, streaming controls) grows from here.
///
/// Every user action here reports its own `tap` event right where it's
/// executed — a picker's `onChange`, a button's action closure — rather than
/// the model doing it on the view's behalf (EVENTS.md, "The `tap`
/// convention"); `model.eventBus` is exposed for exactly this.
struct ContentView: View {
    /// The engine model, bindable so the pickers drive its selection.
    @Bindable var model: EngineModel

    /// The shot the rename dialog is editing, or `nil` while it is closed.
    /// View-local, like the layer editor's selection: which shot is being
    /// renamed is transient session state.
    @State private var shotBeingRenamed: Shot?

    /// The rename dialog's working text, prefilled with the shot's current
    /// name when the dialog opens.
    @State private var renameText = ""

    /// The window body: preview on top, controls beneath.
    var body: some View {
        VStack(spacing: 12) {
            ProgramPreviewView(relay: model.programRelay)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    Text("Program", comment: "Label over the live program preview")
                        .font(.caption.weight(.semibold))
                        .padding(6)
                        .background(.black.opacity(0.4), in: .capsule)
                        .foregroundStyle(.white)
                        .padding(8)
                }

            shotSwitcher

            LayerTreeEditorView(model: model)

            controls
        }
        .padding()
        .onChange(of: model.selectedCameraID) { _, newValue in
            let name = model.cameras.first { $0.id == newValue }?.name ?? "None"
            model.eventBus.tap(
                "camera.picker",
                domain: .capture,
                params: ["id": .string(newValue?.rawValue ?? "none"), "name": .string(name)]
            )
            Task { await model.reconfigure() }
        }
        .onChange(of: model.selectedDisplayID) { _, newValue in
            let name = model.displays.first { $0.id == newValue }?.name ?? "None"
            model.eventBus.tap(
                "display.picker",
                domain: .capture,
                params: ["id": .string(newValue?.rawValue ?? "none"), "name": .string(name)]
            )
            Task { await model.reconfigure() }
        }
    }

    /// The shot switcher: one button per available shot, taking it to program
    /// on tap (a dissolve when ``EngineModel/useDissolveTransition`` is on,
    /// otherwise a cut). The button for the shot currently on program is
    /// highlighted; its context menu duplicates, renames, or removes the
    /// shot, and the trailing Add Shot button appends a new empty one — the
    /// button stays available even when the preset has no shots, so the
    /// operator is never stranded on an empty switcher.
    private var shotSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(model.shots) { shot in
                    let isOnProgram = shot.id == model.activeShotID
                    Button(shot.name) {
                        model.eventBus.tap(
                            ProgramLayout.tapName(forShotID: shot.id),
                            domain: .composition,
                            params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
                        )
                        model.take(shot.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isOnProgram ? .accentColor : .gray)
                    .contextMenu {
                        shotCommands(for: shot)
                    }
                }

                Button {
                    model.eventBus.tap("shotAdd.button", domain: .composition)
                    model.addShot()
                } label: {
                    Label {
                        Text("Add Shot", comment: "Button adding a new empty shot to the preset")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }

            if !model.shots.isEmpty {
                Toggle(isOn: $model.useDissolveTransition) {
                    Text(
                        "Dissolve",
                        comment: "Toggle: use a dissolve transition for the next shot take, instead of a cut")
                }
                .toggleStyle(.checkbox)
                .onChange(of: model.useDissolveTransition) { _, newValue in
                    model.eventBus.tap(
                        "transition.toggle",
                        domain: .composition,
                        params: ["dissolve": .bool(newValue)]
                    )
                }
            }
        }
        .alert(
            Text("Rename Shot", comment: "Rename shot dialog title"),
            isPresented: isRenamePresented,
            presenting: shotBeingRenamed
        ) { shot in
            TextField(text: $renameText) {
                Text("Name", comment: "Rename shot dialog text field label")
            }
            Button {
                model.eventBus.tap(
                    "shotRenameConfirm.button",
                    domain: .composition,
                    params: ["shot": .string(shot.id.rawValue), "name": .string(renameText)]
                )
                model.renameShot(shot.id, to: renameText)
            } label: {
                Text("Rename", comment: "Rename shot dialog confirm button")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    "shotRenameCancel.button",
                    domain: .composition,
                    params: ["shot": .string(shot.id.rawValue)]
                )
            } label: {
                Text("Cancel", comment: "Rename shot dialog cancel button")
            }
        }
    }

    /// Whether the rename dialog is up — presented while a shot is being
    /// renamed, and clearing that shot when the dialog dismisses.
    private var isRenamePresented: Binding<Bool> {
        Binding {
            shotBeingRenamed != nil
        } set: { presented in
            if !presented { shotBeingRenamed = nil }
        }
    }

    /// One shot button's context menu: duplicate, rename, and remove that
    /// shot (ARCHITECTURE.md, "Shot management"). Remove is immediate — a
    /// destructive-role item, no confirmation: shots are quick to create,
    /// switch, and discard (GLOSSARY.md, "Shot").
    @ViewBuilder private func shotCommands(for shot: Shot) -> some View {
        Button {
            model.eventBus.tap(
                "shotDuplicate.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            model.duplicateShot(shot.id)
        } label: {
            Text("Duplicate", comment: "Shot context menu: duplicate this shot")
        }

        Button {
            model.eventBus.tap(
                "shotRename.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            renameText = shot.name
            shotBeingRenamed = shot
        } label: {
            Text("Rename…", comment: "Shot context menu: rename this shot")
        }

        Button(role: .destructive) {
            model.eventBus.tap(
                "shotRemove.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            Task { await model.removeShot(shot.id) }
        } label: {
            Text("Remove Shot", comment: "Shot context menu: remove this shot from the preset")
        }
    }

    /// The camera and display pickers.
    private var controls: some View {
        HStack(spacing: 20) {
            Picker(selection: $model.selectedCameraID) {
                Text("None", comment: "Picker option for no input selected").tag(InputID?.none)
                ForEach(model.cameras) { camera in
                    Text(camera.name).tag(InputID?.some(camera.id))
                }
            } label: {
                Text("Camera", comment: "Camera input picker label")
            }

            Picker(selection: $model.selectedDisplayID) {
                Text("None", comment: "Picker option for no input selected").tag(InputID?.none)
                ForEach(model.displays) { display in
                    Text(display.name).tag(InputID?.some(display.id))
                }
            } label: {
                Text("Display", comment: "Display input picker label")
            }
        }
        .pickerStyle(.menu)
    }
}
