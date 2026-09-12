//
//  LogWindowCommands.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The Window-menu command that opens the Log window, Window ▸ Log.
///
/// A command of its own rather than the item a `Window` scene lists for
/// itself, because that item has no action closure to report a `tap` from; the
/// scene's own commands are removed (``TingraApp/body``), the Settings
/// precedent. No keyboard shortcut in this iteration (ARCHITECTURE.md, "The log
/// window").
struct LogWindowCommands: Commands {
    /// The engine model, for the command's `tap` event.
    let model: EngineModel

    /// Opens the log window.
    @Environment(\.openWindow) private var openWindow

    /// The one Window-menu item, above the list of open windows.
    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button {
                model.eventBus.tap("logWindow.menuItem", domain: .platform)
                openWindow(id: TingraApp.logWindowID)
            } label: {
                Text("Log", comment: "Title of the log window, and its Window-menu command")
            }
            Divider()
        }
    }
}
