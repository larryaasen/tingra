//
//  SettingsButton.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The **Settings** control at the trailing end of the main window's toolbar:
/// a gear that opens the settings window (``SettingsView``), the same window
/// the app menu's Settings… (⌘,) opens.
///
/// It exists because the controls that *configure* the two outputs moved out
/// of the main window on 2026-09-08 — destinations to the Streaming pane, the
/// recordings folder to the Recording pane — while the buttons that *start*
/// them stayed in the toolbar. An operator who reaches for Start Streaming
/// and finds no destination set up now has the way to fix it one click to the
/// right, instead of a trip through the app menu. A gear at the trailing end
/// of the toolbar is where macOS puts a window's settings entry point.
///
/// It sits in its own toolbar item rather than in the group with Fade to
/// Black, Start Streaming, and Record: those three change what goes out to
/// viewers, and this one changes nothing on air. The system draws separate
/// items apart, so the gear reads as a different kind of control.
///
/// The `tap` is named for this surface (`settings.button`) where the menu
/// item's is `settings.menuItem`, so a log reader can tell which the operator
/// used; the shortcut stays on the menu item alone, where macOS reserves it.
struct SettingsButton: View {
    /// The engine model, for the button's `tap` event.
    let model: EngineModel

    /// Opens the settings window.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            model.eventBus.tap("settings.button", domain: .platform)
            openWindow(id: TingraApp.settingsWindowID)
        } label: {
            Label {
                Text("Settings", comment: "Title of the settings window, and the toolbar button that opens it")
            } icon: {
                Image(systemName: "gearshape")
            }
        }
        .labelStyle(.iconOnly)
        .help(Text("Open Settings", comment: "Tooltip on the Settings toolbar button"))
    }
}
