//
//  StatusBarCommands.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The View-menu command that shows or hides the status bar.
///
/// **The title flips rather than carrying a checkmark** — Show Status Bar
/// when it is off, Hide Status Bar when it is on — the macOS convention for
/// this exact item (the Finder's and Safari's View menus) and the main
/// Tingra app's. It takes **⌘/**, the Finder's and Safari's assignment, and
/// sits in a section of its own after the sidebar group, as in the Finder.
///
/// It drives the same ``StatusBarModel`` the settings checkbox writes, so the
/// two can never disagree and either one persists the choice.
struct StatusBarCommands: Commands {
    /// The shared hardware model, for the command's `tap` event.
    let model: HardwareModel

    /// Whether the status bar is shown.
    let statusBar: StatusBarModel

    /// The one View-menu item, in a section of its own.
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button {
                model.recordTap("statusBar.menuItem", params: ["visible": .bool(!statusBar.isVisible)])
                statusBar.isVisible.toggle()
            } label: {
                if statusBar.isVisible {
                    Text("Hide Status Bar", comment: "View menu item that hides the window status bar")
                } else {
                    Text("Show Status Bar", comment: "View menu item that shows the window status bar")
                }
            }
            .keyboardShortcut("/", modifiers: .command)

            Divider()
        }
    }
}
