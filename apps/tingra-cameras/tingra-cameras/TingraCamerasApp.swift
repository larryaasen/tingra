//
//  TingraCamerasApp.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The application entry point for "Tingra Cameras".
///
/// It hosts a single ``ContentView`` in a window sized for the two-column
/// layout and owns the shared ``HardwareModel`` for the session.
@main
struct TingraCamerasApp: App {
    /// The session's hardware-selection state, owned here so it persists for
    /// the window's lifetime and is injected into the view tree. The live
    /// model discovers real hardware through the Tingra engine.
    @State private var model = HardwareModel.live

    /// The app's scene graph: a single resizable window presenting the
    /// hardware picker.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                // A comfortable default that keeps both columns legible; the
                // window remains freely resizable by the operator.
                .frame(minWidth: 820, minHeight: 520)
                // Discover the connected cameras and microphones and start
                // the first camera's live preview once the window appears.
                .task { await model.start() }
        }
    }
}
