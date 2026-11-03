//
//  ContentView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The root layout: a translucent selection sidebar on the left, the
/// live-camera preview canvas in the middle, and the selected camera's
/// controls in the trailing sidebar (``TrailingSidebar``) on the right.
///
/// A `NavigationSplitView` provides the native macOS sidebar chrome — the
/// vibrant material behind the traffic-light controls and the drag-to-resize
/// column divider — while the sidebar's own rows are custom-styled to match
/// the design's highlight capsule and shaped icons.
///
/// The sidebar follows the window's width: the preview column keeps
/// ``minimumWindowWidth`` to itself and the trailing sidebar keeps its own
/// width, so the sidebar needs those plus its own. Narrowing the window past
/// that closes the sidebar, and widening back past it reopens it, unless the
/// operator has changed it since. Opening it in a narrower window widens the
/// window to fit.
///
/// The trailing sidebar never closes on its own, because it holds the only
/// way to reach the camera's controls: while it is open the window can't get
/// narrower than the preview column and the sidebar's minimum together.
struct ContentView: View {
    /// The narrowest the window may be, with both sidebars closed: the
    /// narrowest the preview column stays legible.
    static let minimumWindowWidth: CGFloat = 410

    /// The shared hardware-selection state, injected by the app.
    @Environment(HardwareModel.self) private var model

    /// Whether the sidebar is closed, remembered per window.
    @SceneStorage("sidebar.isHidden") private var isSidebarHidden = false

    /// Whether the window's width closed the sidebar, rather than the
    /// operator, so widening the window should reopen it.
    @SceneStorage("sidebar.wasAutoClosed") private var sidebarWasAutoClosed = false

    /// Whether the trailing sidebar is shown, remembered per window.
    @SceneStorage("trailingSidebar.isPresented") private var isTrailingSidebarPresented = true

    /// The sidebar's width when last open, starting at its ideal width.
    @State private var sidebarWidth: CGFloat = 260

    /// The trailing sidebar's width when last open, starting at its ideal
    /// width.
    @State private var trailingSidebarWidth = TrailingSidebar.idealWidth

    /// The window this view is in, for widening.
    @State private var hostWindow = HostWindow()

    /// The window width the preview column and an open trailing sidebar need
    /// at their current widths.
    private var contentMinimumWindowWidth: CGFloat {
        Self.minimumWindowWidth + (isTrailingSidebarPresented ? trailingSidebarWidth : 0)
    }

    /// The window width the sidebar needs: the preview column's and trailing
    /// sidebar's plus the sidebar itself.
    private var sidebarMinimumWindowWidth: CGFloat { contentMinimumWindowWidth + sidebarWidth }

    /// The narrowest the window may be right now: the preview column's
    /// minimum and, while it is open, the trailing sidebar's.
    private var currentMinimumWindowWidth: CGFloat {
        Self.minimumWindowWidth + (isTrailingSidebarPresented ? TrailingSidebar.minimumWidth : 0)
    }

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

    /// The trailing sidebar's visibility as the inspector column, the toolbar
    /// button, and the View menu drive it: the operator's own changes.
    private var trailingSidebarPresented: Binding<Bool> {
        Binding {
            isTrailingSidebarPresented
        } set: { isPresented in
            guard isPresented != isTrailingSidebarPresented else { return }
            isTrailingSidebarPresented = isPresented
            if isPresented {
                hostWindow.widen(to: isSidebarHidden ? contentMinimumWindowWidth : sidebarMinimumWindowWidth)
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
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: { width in
                    // A closed sidebar measures nothing, and its last width
                    // is the one it reopens at.
                    if width > 0 { sidebarWidth = width }
                }
                // Outermost: under the geometry reader above, a first launch
                // ignored these and opened the sidebar at 148 points.
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            // The status bar rides on the detail column, not under the whole
            // split view: the sidebar's material runs the full height of the
            // window.
            PreviewCanvasView()
                // Device names are proper nouns from the system, and the
                // product name is the same in every language.
                .navigationTitle(Text(verbatim: model.selectedCamera?.name ?? "Tingra Cameras"))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StatusBarView()
                }
                // Outside the status bar's inset, so the bar stays under the
                // preview column and the trailing sidebar's material runs the
                // full height of the window, as the leading sidebar's does.
                .inspector(isPresented: trailingSidebarPresented) {
                    TrailingSidebar()
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.width
                        } action: { width in
                            // A closed sidebar measures nothing, and its last
                            // width is the one it reopens at.
                            if width > 0 { trailingSidebarWidth = width }
                        }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        InspectorButton(isPresented: trailingSidebarPresented)
                    }
                }
        }
        .focusedSceneValue(\.isInspectorPresented, trailingSidebarPresented)
        // The window's width only, so dragging a sidebar's divider never
        // closes a sidebar.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            followWindowWidth($0)
        }
        .background(HostWindowReader(host: hostWindow))
        .frame(minWidth: currentMinimumWindowWidth)
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
