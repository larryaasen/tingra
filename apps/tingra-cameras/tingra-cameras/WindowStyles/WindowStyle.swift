//
//  WindowStyle.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI

/// The two shapes a Tingra Cameras window comes in, each its own window
/// group.
///
/// **Compact**, the default, is one narrow column: a camera picker over the
/// preview over the controls (``CompactWindowView``). **Standard** is the
/// three-column window: the sidebar of presets and cameras, the preview, and
/// the camera's controls in the trailing sidebar (``ContentView``). Each
/// window shows its own camera (``CameraSession``), and any number of either
/// style can be open. The operator switches a window between them from the
/// Window menu (``WindowStyleCommands``), the way the Music app's Window menu
/// switches to and from its MiniPlayer.
enum WindowStyle: String, CaseIterable {
    /// The three-column window: sidebar, preview, trailing sidebar.
    case standard
    /// The narrow one-column window: picker, preview, controls.
    case compact

    /// The scene identifier ``TingraCamerasApp`` gives the style's scene,
    /// which `openWindow(id:)` opens.
    var sceneID: String {
        switch self {
        case .standard: "standard"
        case .compact: "compact"
        }
    }

    /// The style a window of this style switches to.
    var other: WindowStyle {
        switch self {
        case .standard: .compact
        case .compact: .standard
        }
    }
}

/// Where the style a launch and a new window open lives: **machine-local
/// preferences**, like the status bar's. It is the style the operator last
/// switched to, so an operator who works in the standard window gets it back
/// at the next launch and from File ▸ New Window, rather than the compact
/// window every install starts with.
struct WindowStylePreferences {
    /// The defaults database the value lives in (injectable, so a test runs
    /// against its own suite rather than the user's).
    private let defaults: UserDefaults

    /// The launch style key.
    private static let launchStyleKey = "window.style"

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The style a launch and File ▸ New Window open. A missing or unknown
    /// value reads ``WindowStyle/compact``, the window every install starts
    /// with: the smaller window, switched to the standard one from the Window
    /// menu when the operator wants the sidebars.
    var launchStyle: WindowStyle {
        get {
            defaults.string(forKey: Self.launchStyleKey).flatMap(WindowStyle.init(rawValue:)) ?? .compact
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.launchStyleKey) }
    }
}

/// What the key window tells the Window menu so its item can switch it:
/// which style the window is, the window itself, to close once the other
/// style's window is open, and its camera session, whose camera the new
/// window opens on.
struct WindowStyleSwitcher {
    /// The key window's style.
    let style: WindowStyle

    /// The key window, closed by the switch.
    let window: HostWindow

    /// The key window's camera session.
    let session: CameraSession
}

extension FocusedValues {
    /// The key window's style and window, for the Window menu's Switch to
    /// Compact Window / Switch to Standard Window item. Nil with no Tingra
    /// Cameras window key (none open, or Settings in front).
    @Entry var windowStyleSwitcher: WindowStyleSwitcher?
}
