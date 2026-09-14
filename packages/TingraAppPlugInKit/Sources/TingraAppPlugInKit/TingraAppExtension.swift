//
//  TingraAppExtension.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ExtensionFoundation
import ExtensionKit
import Foundation
import SwiftUI
import TingraPlugInKit

/// What an app-tier plug-in's `@main` type adopts: ExtensionKit's
/// `AppExtension` with the boilerplate owned by the kit. An author declares
/// panes and commands in the Info.plist manifest (``PlugInManifest``),
/// returns a view per pane, and performs commands; the kit turns the
/// manifest into one extension scene per pane and settings pane, accepts
/// every connection the app opens, and runs the MCP handshake on each
/// (PLUGINS.md, Phase 1, "`TingraAppExtension`").
///
/// `@MainActor`: an extension's `init` and `configuration` are main-actor
/// requirements of `AppExtension`, and panes are views. The command
/// handler the kit builds is main-actor isolated too, so the extension
/// performs commands on the main actor however XPC delivered them.
@MainActor
public protocol TingraAppExtension: AppExtension where Configuration == AppExtensionSceneConfiguration {
    /// The one view type the extension's panes share; switch on the id
    /// inside a `@ViewBuilder`.
    associatedtype PaneBody: View

    /// The manifest, read from the extension's Info.plist by default.
    var manifest: PlugInManifest { get }

    /// The view for a pane or settings pane the manifest declares.
    ///
    /// - Parameter id: The pane's identifier.
    @ViewBuilder func pane(for id: PaneID) -> PaneBody

    /// Performs a command the operator invoked; the app has already emitted
    /// the `tap`, so the plug-in's own event is the command's effect.
    ///
    /// - Parameters:
    ///   - command: The command's identifier.
    ///   - connection: The connection the command arrived on.
    func perform(_ command: CommandID, using connection: PlugInConnection) async throws
}

extension TingraAppExtension {
    /// The manifest from the extension's own Info.plist. A manifest that
    /// does not decode is a programming error in the extension, reported
    /// once and replaced by an empty manifest so the process still starts.
    public var manifest: PlugInManifest {
        do {
            return try PlugInManifest(bundle: .main)
        } catch {
            return PlugInManifest(id: PlugInID(rawValue: Bundle.main.bundleIdentifier ?? "unknown"), name: "")
        }
    }

    /// One scene per pane and settings pane, each accepting the app's
    /// connection, plus the handler for the app's command connection.
    public var configuration: AppExtensionSceneConfiguration {
        let manifest = manifest
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let handler = PlugInCommandHandler(manifest: manifest, version: version) { command, connection in
            try await self.perform(command, using: connection)
        }
        let sceneIDs = manifest.panes.map { ($0.id, $0.sceneID) } + manifest.settingsPanes.map { ($0.id, $0.sceneID) }
        let scenes = sceneIDs.map { paneID, sceneID in
            PrimitiveAppExtensionScene(id: sceneID) {
                pane(for: paneID).environment(PlugInRuntime.shared)
            } onConnection: { connection in
                handler.accept(connection)
                return true
            }
        }
        return AppExtensionSceneConfiguration(scenes, configuration: handler)
    }
}

/// Accepts the app's connections — the command connection through
/// `AppExtensionConfiguration`, the pane connections through each scene —
/// and hands them to ``PlugInRuntime``.
public struct PlugInCommandHandler: AppExtensionConfiguration {
    /// The plug-in id and version reported to the app.
    private let clientName: String

    /// The plug-in's version.
    private let clientVersion: String

    /// Performs commands the app forwards.
    private let performCommand: PlugInConnection.CommandHandler

    /// Creates the handler.
    ///
    /// - Parameters:
    ///   - manifest: The plug-in's manifest.
    ///   - version: The plug-in's version.
    ///   - performCommand: Performs commands the app forwards.
    public init(manifest: PlugInManifest, version: String, performCommand: @escaping PlugInConnection.CommandHandler) {
        clientName = manifest.id.rawValue
        clientVersion = version
        self.performCommand = performCommand
    }

    /// Accepts a connection the app opened.
    ///
    /// - Parameter connection: The connection, not yet resumed.
    /// - Returns: `true`; every connection the app opens is accepted.
    nonisolated public func accept(connection: NSXPCConnection) -> Bool {
        accept(connection)
        return true
    }

    /// Hands a connection to the runtime.
    nonisolated func accept(_ connection: NSXPCConnection) {
        PlugInRuntime.accept(
            connection, clientName: clientName, clientVersion: clientVersion, performCommand: performCommand)
    }
}
