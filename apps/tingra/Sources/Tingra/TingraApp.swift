//
//  TingraApp.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The Tingra app entry point (phase 3, scaffolded at roadmap step 6).
///
/// It owns the ``EngineModel`` — the one `@Observable` that boots the host,
/// activates the capture and generator plug-ins, and drives the compositor —
/// and hands it to the main window. The engine starts once the window
/// appears; production controls (presets, shots, the mixer) hang off this
/// same model as they land.
@main
struct TingraApp: App {
    /// The engine model, owned for the app's lifetime.
    @State private var model = EngineModel()

    /// The single-window scene: the program preview and its input pickers.
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
                .frame(minWidth: 640, minHeight: 480)
        }
    }
}
