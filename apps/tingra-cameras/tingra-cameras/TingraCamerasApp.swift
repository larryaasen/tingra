//
//  TingraCamerasApp.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The application for "Tingra Cameras".
///
/// It hosts ``ContentView`` in a window sized for the two-column layout —
/// File ▸ New Window opens more, all showing the same camera — beside the
/// settings window (``SettingsView``), and owns the shared ``HardwareModel``
/// for the session. It is not the `@main` entry: ``TingraCamerasMain`` is,
/// so `--version` answers before this value and its engine exist.
struct TingraCamerasApp: App {
    /// The session's hardware-selection state, owned here so it persists for
    /// the window's lifetime and is injected into the view tree. The live
    /// model discovers real hardware through the Tingra engine.
    @State private var model = HardwareModel.live

    /// The app's appearance, owned for the app's lifetime and installed on
    /// the application as it is created, so the first window is drawn in it.
    @State private var appearance = AppearanceModel()

    /// Whether the windows carry a status bar, shared by every window and the
    /// settings window that edits it.
    @State private var statusBar = StatusBarModel()

    /// When the app launched, recorded as it is created; the About pane's
    /// uptime counts from here (see ``AppUptime``).
    @State private var uptime = AppUptime()

    /// The identifier the app menu's Settings… command opens.
    static let settingsWindowID = "settings"

    /// The app's scene graph: a single resizable window presenting the
    /// hardware picker.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(statusBar)
                // The minimum width follows the trailing sidebar, so it is
                // set in ``ContentView``. The window remains freely resizable
                // by the operator.
                .frame(minHeight: 520)
                // Discover the connected cameras and start
                // the first camera's live preview once the window appears.
                .task { await model.start() }
        }
        // Tall enough for the camera's controls in the trailing sidebar, and
        // wide enough to leave the preview a generous column beside them.
        .defaultSize(width: 1280, height: 900)
        .commands {
            PreviewCommands(model: model)
            PresetCommands(model: model)
            InspectorCommands(model: model)
            StatusBarCommands(model: model, statusBar: statusBar)
            SettingsCommands(model: model)
        }

        // Settings is a `Window` rather than the `Settings` scene, so its
        // source list runs the full height of the window as the main
        // window's sidebar does (see ``SettingsView``). `SettingsCommands`
        // puts Settings… where macOS reserves it, under ⌘, in the app menu;
        // `commandsRemoved()` drops the scene's own Window-menu item so that
        // stays the only one.
        Window(
            String(localized: "Settings", comment: "Title of the settings window"),
            id: Self.settingsWindowID
        ) {
            SettingsView(appearance: appearance, statusBar: statusBar, uptime: uptime)
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}
