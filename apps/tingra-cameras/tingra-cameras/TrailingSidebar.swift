//
//  TrailingSidebar.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-31.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The window's trailing sidebar, the main Tingra app's shape and width: the
/// selected camera's controls (``CameraControlsView``), or the empty state
/// while no camera is selected. Shown and hidden by ⌥⌘I and the toolbar's
/// trailing button (``InspectorCommands``, ``InspectorButton``).
struct TrailingSidebar: View {
    /// The narrowest the sidebar may be, and its starting width.
    static let minimumWidth: CGFloat = 280
    static let idealWidth: CGFloat = 320

    /// The widest the sidebar may be, so it never starves the preview.
    private static let maximumWidth: CGFloat = 440

    /// The window's camera session: the camera it shows and that camera's
    /// controls and values.
    @Environment(CameraSession.self) private var session

    /// The controls, or the empty state.
    var body: some View {
        Group {
            if session.selectedCamera != nil {
                CameraControlsView()
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No Camera Selected", comment: "Trailing sidebar empty state title")
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                    }
                } description: {
                    Text(
                        "Select a camera to adjust its controls.",
                        comment: "Trailing sidebar empty state description"
                    )
                }
            }
        }
        .inspectorColumnWidth(min: Self.minimumWidth, ideal: Self.idealWidth, max: Self.maximumWidth)
    }
}

#Preview {
    TrailingSidebar()
        .previewEnvironment()
        .frame(width: TrailingSidebar.idealWidth, height: 600)
}
