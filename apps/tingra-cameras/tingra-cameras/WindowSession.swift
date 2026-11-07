//
//  WindowSession.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// Gives a window its own camera: a ``CameraSession`` owned for the window's
/// lifetime, started as the window appears and stopped as it closes, so
/// each window can show a different camera.
///
/// Both window styles wear it (``WindowStyle``), which is what keeps their
/// per-window plumbing in one place: the session in the environment and in
/// the key window's focused scene values (for the menu bar's Copy and
/// Presets commands, and the Window menu's style switch), its preset
/// dialogs, and the camera it shows remembered in
/// `@SceneStorage`, so a window macOS restores reopens on its own camera.
struct WindowSession: ViewModifier {
    /// The style of the window this is.
    let style: WindowStyle

    /// The shared model, which the session starts against.
    @Environment(HardwareModel.self) private var model

    /// The window's camera session, owned here for the window's lifetime.
    @State private var session = CameraSession()

    /// The window, for the Window menu's style switch to close.
    @State private var hostWindow = HostWindow()

    /// The identifier of the camera the window shows, remembered with the
    /// window so a restored window reopens on it.
    @SceneStorage("camera.id") private var cameraID: String?

    /// That camera's name, the fallback when its identifier changes because
    /// it was plugged into another port.
    @SceneStorage("camera.name") private var cameraName: String?

    /// Attaches the session and the window's per-window state.
    func body(content: Content) -> some View {
        content
            // On the window's root rather than the sidebar, so the Presets
            // menu can open a dialog with the sidebar collapsed or absent.
            .presetDialogs(model: model, session: session)
            .environment(session)
            .focusedSceneValue(\.cameraSession, session)
            .focusedSceneValue(
                \.windowStyleSwitcher,
                WindowStyleSwitcher(style: style, window: hostWindow, session: session)
            )
            .background(HostWindowReader(host: hostWindow))
            .task {
                await session.start(model: model, restoringCameraID: cameraID, name: cameraName)
            }
            .onChange(of: session.selectedCamera) { _, camera in
                guard let camera else { return }
                cameraID = camera.id
                cameraName = camera.name
            }
            // The camera keeps running for any other window showing it.
            .onDisappear {
                Task { await session.stop() }
            }
    }
}

extension View {
    /// Gives this window its own camera (``WindowSession``).
    ///
    /// - Parameter style: The style of the window this is.
    /// - Returns: The window's root view, with its session.
    func windowSession(_ style: WindowStyle) -> some View {
        modifier(WindowSession(style: style))
    }
}
