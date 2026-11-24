//
//  TingraCamerasAppDelegate.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit

/// The application delegate, for the one app-level behavior SwiftUI has no
/// scene modifier for: quitting when the last window closes.
///
/// Tingra Cameras is a single-purpose utility, and the Human Interface
/// Guidelines have such an app quit with its last window rather than linger
/// with nothing on screen. Switching window styles opens the new window
/// before closing the old one, so a switch never counts as the last window
/// closing.
final class TingraCamerasAppDelegate: NSObject, NSApplicationDelegate {
    /// Quits once the last window, the settings window included, closes.
    ///
    /// - Parameter sender: The application.
    /// - Returns: Always true.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
