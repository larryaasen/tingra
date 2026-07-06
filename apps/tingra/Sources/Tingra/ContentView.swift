//
//  ContentView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The main window: the program preview above its input pickers.
///
/// The pickers pick one camera and one display; the compositor composites
/// the display full-frame with the camera as a corner picture-in-picture,
/// and the preview shows the live program. This is the step-6 shape — the
/// production surface (presets, shots, the mixer, streaming controls) grows
/// from here.
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

            controls
        }
        .padding()
        .onChange(of: model.selectedCameraID) {
            Task { await model.reconfigure() }
        }
        .onChange(of: model.selectedDisplayID) {
            Task { await model.reconfigure() }
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
