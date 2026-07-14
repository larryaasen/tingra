//
//  ContentView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The root two-column layout: a translucent selection sidebar on the left
/// and the live-camera preview canvas on the right.
///
/// A `NavigationSplitView` provides the native macOS sidebar chrome — the
/// vibrant material behind the traffic-light controls and the drag-to-resize
/// column divider — while the sidebar's own rows are custom-styled to match
/// the design's highlight capsule and shaped icons.
struct ContentView: View {
    /// The shared hardware-selection state, injected by the app.
    @Environment(HardwareModel.self) private var model

    /// Composes the sidebar and detail columns.
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            PreviewCanvasView()
        }
    }
}

#Preview {
    ContentView()
        .environment(HardwareModel.preview)
        .frame(width: 900, height: 560)
}
