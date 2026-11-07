//
//  WindowStyleCommands.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The Window menu's **Switch to Compact Window** / **Switch to Standard
/// Window** item: it opens the other style's window and closes the key one,
/// the Music app's Switch to MiniPlayer item for this app's two window
/// styles (``WindowStyle``).
///
/// The new window shows the camera the key window showed. The title names
/// the style the key window would become, so it flips with the key window.
/// The choice is remembered (``WindowStylePreferences``), so the next launch
/// and File ▸ New Window open the style switched to. With no Tingra Cameras
/// window key, there is nothing to switch, so the item is disabled.
struct WindowStyleCommands: Commands {
    /// The shared hardware model, for the command's `tap` event.
    let model: HardwareModel

    /// Where the style the next launch opens persists.
    let preferences: WindowStylePreferences

    /// The key window's style and window, or nil with none key.
    @FocusedValue(\.windowStyleSwitcher) private var switcher

    /// Opens the other style's window.
    @Environment(\.openWindow) private var openWindow

    /// The item, in a section of its own after Minimize and Zoom.
    var body: some Commands {
        CommandGroup(after: .windowSize) {
            Divider()

            Button {
                guard let switcher else { return }
                let target = switcher.style.other
                model.recordTap("windowStyle.menuItem", params: ["style": .string(target.rawValue)])
                preferences.launchStyle = target
                // The new window opens on the camera the operator last chose,
                // so make that this window's: the switch keeps the camera.
                if let camera = switcher.session.selectedCamera {
                    model.rememberSelectedCamera(camera)
                }
                // Open first, so the app never has a moment with no window.
                openWindow(id: target.sceneID)
                switcher.window.close()
            } label: {
                Self.title(switchingTo: (switcher?.style ?? .standard).other)
            }
            .disabled(switcher == nil)
        }
    }

    /// The item's title for the style it switches to.
    ///
    /// - Parameter style: The style the key window would become.
    /// - Returns: Switch to Compact Window, or Switch to Standard Window.
    private static func title(switchingTo style: WindowStyle) -> Text {
        switch style {
        case .compact:
            Text(
                "Switch to Compact Window",
                comment: "Window menu item replacing the three-column window with the narrow one-column window"
            )
        case .standard:
            Text(
                "Switch to Standard Window",
                comment: "Window menu item replacing the narrow one-column window with the three-column window"
            )
        }
    }
}

/// File ▸ **New Window** (⌘N), opening a window of the operator's style —
/// compact until they switch to standard (``WindowStylePreferences``) —
/// rather than SwiftUI's own item, which always opens the first window
/// group. The new window opens on the camera the operator last chose, and
/// from there shows its own.
struct NewWindowCommands: Commands {
    /// The shared hardware model, for the command's `tap` event.
    let model: HardwareModel

    /// Where the operator's window style persists.
    let preferences: WindowStylePreferences

    /// Opens the window.
    @Environment(\.openWindow) private var openWindow

    /// The item, in place of SwiftUI's.
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                let style = preferences.launchStyle
                model.recordTap("newWindow.menuItem", params: ["style": .string(style.rawValue)])
                openWindow(id: style.sceneID)
            } label: {
                Text("New Window", comment: "File menu item opening another camera window")
            }
            .keyboardShortcut("n")
        }
    }
}
