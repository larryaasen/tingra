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
///
/// The sidebar follows the window's width: the preview column keeps
/// ``minimumWindowWidth`` to itself, so the sidebar needs that plus its own
/// width. Narrowing the window past that closes the sidebar, and widening
/// back past it reopens it, unless the operator has changed it since. Opening
/// it in a narrower window widens the window to fit.
struct ContentView: View {
    /// The narrowest the window may be, with the sidebar closed: the
    /// narrowest the preview column stays legible.
    static let minimumWindowWidth: CGFloat = 410

    /// The shared hardware-selection state, injected by the app.
    @Environment(HardwareModel.self) private var model

    /// Whether the sidebar is closed, remembered per window.
    @SceneStorage("sidebar.isHidden") private var isSidebarHidden = false

    /// Whether the window's width closed the sidebar, rather than the
    /// operator, so widening the window should reopen it.
    @SceneStorage("sidebar.wasAutoClosed") private var sidebarWasAutoClosed = false

    /// The sidebar's width when last open, starting at its ideal width.
    @State private var sidebarWidth: CGFloat = 260

    /// The window this view is in, for widening.
    @State private var hostWindow = HostWindow()

    /// The window width the sidebar needs: the preview column's minimum plus
    /// the sidebar itself.
    private var sidebarMinimumWindowWidth: CGFloat { Self.minimumWindowWidth + sidebarWidth }

    /// The sidebar's visibility as the split view drives it. Only the
    /// operator's own changes come through here: the sidebar button and the
    /// View menu.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            isSidebarHidden ? .detailOnly : .all
        } set: { visibility in
            let hides = visibility == .detailOnly
            guard hides != isSidebarHidden else { return }
            isSidebarHidden = hides
            sidebarWasAutoClosed = false
            if !hides {
                hostWindow.widen(to: sidebarMinimumWindowWidth)
            }
        }
    }

    /// Closes the sidebar when the window gets too narrow for it, and
    /// reopens it when the window gets wide enough again if that's what
    /// closed it.
    ///
    /// - Parameter width: The window's new width.
    private func followWindowWidth(_ width: CGFloat) {
        if width < sidebarMinimumWindowWidth {
            guard !isSidebarHidden else { return }
            isSidebarHidden = true
            sidebarWasAutoClosed = true
        } else if sidebarWasAutoClosed {
            isSidebarHidden = false
            sidebarWasAutoClosed = false
        }
    }

    /// Composes the sidebar and detail columns.
    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: { width in
                    // A closed sidebar measures nothing, and its last width
                    // is the one it reopens at.
                    if width > 0 { sidebarWidth = width }
                }
        } detail: {
            // The status bar rides on the detail column, not under the whole
            // split view: the sidebar's material runs the full height of the
            // window. A bottom safe-area inset, so it stays put while the
            // controls scroll.
            PreviewCanvasView()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StatusBarView()
                }
        }
        // The window's width only, so dragging the sidebar's divider never
        // closes the sidebar.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            followWindowWidth($0)
        }
        .background(HostWindowReader(host: hostWindow))
        // On the window's root rather than the sidebar, so the Presets menu
        // can open a dialog with the sidebar collapsed.
        .presetDialogs(model: model)
    }
}

#Preview {
    ContentView()
        .environment(HardwareModel.preview)
        .environment(StatusBarModel())
        .frame(width: 900, height: 560)
}
