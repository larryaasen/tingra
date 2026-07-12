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

/// The main window: the program preview above the shot switcher and input
/// pickers.
///
/// The pickers pick one camera and one display; the switcher takes the
/// chosen shot (picture-in-picture, display, camera) to program — a cut, or
/// a dissolve when the switcher's transition toggle is on (GLOSSARY.md,
/// "Transition"). This is the early step-7 shape — the production surface
/// (multiple presets, the layer-tree editor, the mixer, streaming controls)
/// grows from here.
///
/// Every user action here reports its own `tap` event right where it's
/// executed — a picker's `onChange`, a button's action closure — rather than
/// the model doing it on the view's behalf (EVENTS.md, "The `tap`
/// convention"); `model.eventBus` is exposed for exactly this.
struct ContentView: View {
    /// The engine model, bindable so the pickers drive its selection.
    @Bindable var model: EngineModel

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
    /// highlighted. Hidden when no input is selected (there are no shots to
    /// switch among).
    @ViewBuilder private var shotSwitcher: some View {
        if !model.shots.isEmpty {
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
                    }
                }

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
