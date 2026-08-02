//
//  TingraApp.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

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

    /// The identifier the View menu's Multiview command opens.
    static let multiviewWindowID = "multiview"

    /// The scenes: the main production window, plus the multiview monitoring
    /// window it can open.
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
                .frame(minWidth: 640, minHeight: 480)
        }
        .commands {
            MultiviewCommands(model: model)
        }

        // Multiview is a **separate window**, not a panel: the main window
        // already carries both monitors, both switcher rows, the layer
        // editor, the mixer, and the destination list, and a tile grid would
        // compete with the very surfaces it duplicates. A window also puts it
        // on a second display for free — and its closed state is what makes
        // multiview genuinely free, since nothing draws and nothing is read
        // while it is shut (ARCHITECTURE.md, "Multiview").
        Window(
            String(
                localized: "Multiview",
                comment: "Title of the multiview monitoring window, and its View-menu command"
            ),
            id: Self.multiviewWindowID
        ) {
            MultiviewView(model: model)
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}

/// The View-menu command that opens the multiview window.
///
/// Its own `Commands` type rather than an inline group so it can take
/// `openWindow` from the environment, and so the `tap` fires where the user
/// action is executed (EVENTS.md, "The `tap` convention") rather than in the
/// app's scene body.
struct MultiviewCommands: Commands {
    /// The engine model, for the command's `tap` event.
    let model: EngineModel

    /// Opens the multiview window.
    @Environment(\.openWindow) private var openWindow

    /// A single View-menu item, with the conventional secondary-window
    /// shortcut.
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button {
                model.eventBus.tap("multiview.menuItem", domain: .composition)
                openWindow(id: TingraApp.multiviewWindowID)
            } label: {
                Text("Multiview", comment: "Title of the multiview monitoring window, and its View-menu command")
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}
