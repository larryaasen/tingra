//
//  PlugInPaneHost.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import ExtensionFoundation
import ExtensionKit
import SwiftUI
import TingraAppPlugInKit

/// Hosts one pane's extension scene: an `EXHostViewController` under
/// `NSViewControllerRepresentable`, reporting activation and deactivation
/// to ``AppPlugInHost`` so the pane's session opens and closes with the
/// scene. Recreated by generation after the extension process dies
/// (PLUGINS.md, "Spike findings", row 2).
struct PlugInPaneHost: NSViewControllerRepresentable {
    /// The extension whose scene is hosted.
    let identity: AppExtensionIdentity

    /// The pane.
    let pane: PaneID

    /// The scene to host.
    let sceneID: String

    /// The host the lifecycle is reported to.
    let host: AppPlugInHost

    /// Creates the host view controller for the scene, with the app's
    /// placeholder until the scene draws.
    func makeNSViewController(context: Context) -> EXHostViewController {
        let controller = EXHostViewController()
        controller.configuration = .init(appExtension: identity, sceneID: sceneID)
        controller.delegate = context.coordinator
        controller.placeholderView = NSHostingView(
            rootView: Text(
                "Loading plug-in…", comment: "Placeholder shown in a plug-in's pane until its extension draws"
            )
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        return controller
    }

    /// Nothing to update; the scene is fixed for the controller's lifetime.
    func updateNSViewController(_ controller: EXHostViewController, context: Context) {}

    /// Creates the delegate bridge.
    func makeCoordinator() -> Coordinator { Coordinator(pane: pane, host: host) }

    /// Forwards the host view controller's lifecycle to the plug-in host.
    final class Coordinator: NSObject, EXHostViewControllerDelegate {
        /// The pane.
        let pane: PaneID

        /// The host the lifecycle is reported to.
        let host: AppPlugInHost

        /// Creates the bridge.
        init(pane: PaneID, host: AppPlugInHost) {
            self.pane = pane
            self.host = host
        }

        func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            host.paneActivated(pane, controller: viewController)
        }

        func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: (any Error)?) {
            host.paneDeactivated(pane, error: error)
        }
    }
}
