//
//  PlugInSceneView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ExtensionFoundation
import SwiftUI
import TingraAppPlugInKit

/// One plug-in scene wherever the app shows one — a sidebar pane, a settings
/// pane, a plug-in window: the hosted scene (``PlugInPaneHost``), recreated
/// by generation when it is tried again, or, once the host has stopped
/// trying, a notice that the plug-in could not start with a way to ask again
/// (PLUGINS.md, "A pane that cannot start").
///
/// One view for the three places so none of them can sit behind "Loading
/// plug-in…" with nothing happening.
struct PlugInSceneView: View {
    /// The extension whose scene is hosted.
    let identity: AppExtensionIdentity

    /// The pane, settings pane, or window.
    let pane: PaneID

    /// The scene to host.
    let sceneID: String

    /// The host the lifecycle is reported to.
    let host: AppPlugInHost

    var body: some View {
        if host.paneFailures[pane] != nil {
            ContentUnavailableView {
                Label {
                    Text(
                        "Plug-in Could Not Start",
                        comment: "Title shown in a plug-in's pane after its extension could not be started")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(
                    "macOS did not start this plug-in. The log has the reason.",
                    comment: "Explanation shown in a plug-in's pane after its extension could not be started")
            } actions: {
                Button {
                    host.retryPane(pane)
                } label: {
                    Text("Try Again", comment: "Button that starts a plug-in's pane again after it could not start")
                }
            }
        } else {
            PlugInPaneHost(identity: identity, pane: pane, sceneID: sceneID, host: host)
                .id(host.paneGenerations[pane, default: 0])
        }
    }
}
