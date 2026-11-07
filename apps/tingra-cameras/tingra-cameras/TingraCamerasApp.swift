//
//  TingraCamerasApp.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI

/// The application for "Tingra Cameras".
///
/// It hosts ``CompactWindowView`` in the narrow compact window, the
/// default, and ``ContentView`` in the standard three-column window the
/// Window menu switches to (``WindowStyle``) — File ▸ New Window opens more
/// of the operator's style, each showing its own camera — beside the
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

    /// Where the window style a launch and File ▸ New Window open persists,
    /// and the Window menu writes it.
    private let windowStylePreferences = WindowStylePreferences()

    /// The window style this launch opens: the one the operator last
    /// switched to, read once, because only a launch acts on it.
    private let launchStyle = WindowStylePreferences().launchStyle

    /// The identifier the app menu's Settings… command opens.
    static let settingsWindowID = "settings"

    /// Turns off window tabbing before any window exists: a window here is a
    /// camera of its own, never a tab, so View ▸ Show Tab Bar and the Window
    /// menu's tab items have no place in the app.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// The app's scene graph: the compact and the standard windows, any
    /// number of either, each showing its own camera (``CameraSession``), and
    /// the settings window. A launch and File ▸ New Window open the window
    /// style the operator last switched to, compact until they switch
    /// (``WindowStyle``).
    var body: some Scene {
        // The compact window, the default, sized by its content within the
        // width bounds ``CompactWindowView`` sets.
        WindowGroup(id: WindowStyle.compact.sceneID) {
            CompactWindowView()
                .windowSession(.compact)
                .environment(model)
                .environment(statusBar)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: CompactWindowView.idealWidth, height: CompactWindowView.idealHeight)
        .defaultLaunchBehavior(launchStyle == .compact ? .presented : .suppressed)
        .commands {
            NewWindowCommands(model: model, preferences: windowStylePreferences)
            PreviewCommands(model: model)
            PresetCommands(model: model)
            InspectorCommands(model: model)
            StatusBarCommands(model: model, statusBar: statusBar)
            SettingsCommands(model: model)
            WindowStyleCommands(model: model, preferences: windowStylePreferences)
        }

        // The standard window: the sidebar, the preview, and the trailing
        // sidebar.
        WindowGroup(id: WindowStyle.standard.sceneID) {
            ContentView()
                .windowSession(.standard)
                .environment(model)
                .environment(statusBar)
                // The minimum width follows the trailing sidebar, so it is
                // set in ``ContentView``. The window remains freely resizable
                // by the operator.
                .frame(minHeight: 520)
        }
        // Tall enough for the camera's controls in the trailing sidebar, and
        // wide enough to leave the preview a generous column beside them.
        .defaultSize(width: 1280, height: 900)
        .defaultLaunchBehavior(launchStyle == .standard ? .presented : .suppressed)

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
