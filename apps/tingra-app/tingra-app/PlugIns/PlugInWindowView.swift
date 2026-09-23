//
//  PlugInWindowView.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraAppPlugInKit

/// The content of a plug-in's window: the hosted extension scene the
/// window's descriptor names, filling the window, titled as the manifest
/// declares (PLUGINS.md, Phase 2, "More app-tier registries"). The app
/// supplies the window — its title bar, its place in the Window menu, its
/// restored frame — and the plug-in draws inside it, the pane rule applied
/// to a window.
///
/// The window is looked up in the registry on every draw rather than handed
/// in, because the system restores an open window at launch before
/// discovery has run: the view waits on the registry and fills in the moment
/// the plug-in is discovered, and says so plainly when the plug-in is gone —
/// disabled or uninstalled with its window left open.
struct PlugInWindowView: View {
    /// The window to host, or nil when the system opened the scene with no
    /// value.
    let window: PaneID?

    /// The host whose registry names the window's scene.
    let host: AppPlugInHost

    /// The hosted scene, or the unavailable notice.
    var body: some View {
        if let window, let registered = host.panes.window(window),
            let plugIn = host.plugIns.first(where: { $0.id == registered.plugIn })
        {
            PlugInPaneHost(identity: plugIn.identity, pane: window, sceneID: registered.descriptor.sceneID, host: host)
                .id(host.paneGenerations[window, default: 0])
                .navigationTitle(Text(verbatim: registered.descriptor.title))
        } else {
            ContentUnavailableView {
                Label {
                    Text(
                        "Plug-in Unavailable",
                        comment: "Title shown in a plug-in's window when the plug-in is disabled or not installed")
                } icon: {
                    Image(systemName: "puzzlepiece.extension")
                }
            } description: {
                Text(
                    "The plug-in that owns this window is not available.",
                    comment: "Explanation shown in a plug-in's window when the plug-in is disabled or not installed")
            }
            .navigationTitle(
                Text("Plug-in", comment: "Title of a plug-in's window while the plug-in that owns it is unavailable"))
        }
    }
}
