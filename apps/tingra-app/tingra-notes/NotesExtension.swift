//
//  NotesExtension.swift
//  TingraNotes
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ExtensionFoundation
import ExtensionKit
import SwiftUI
import TingraAppPlugInKit
import TingraPlugInKit

/// Notes, the first-party proof of the app tier (PLUGINS.md, Decision 9):
/// an ExtensionKit extension embedded in Tingra.app that adds a pane to the
/// trailing sidebar for notes that save with the project, a "Show Notes"
/// command, and a settings pane for the editor's font size — from its own
/// sandboxed process, through the same kit a third party links. It cannot
/// reach the engine: it is not even in the engine's process.
///
/// The panes and the command are declared in the Info.plist manifest
/// (`TingraNotes-Info.plist`); the kit turns them into scenes.
///
/// The conformance is isolated to the main actor explicitly: the target's
/// default isolation makes the `AppExtension` conformance an isolated one,
/// and a conformance that depends on it must say so.
@main
final class NotesExtension: @MainActor TingraAppExtension {
    /// The pane's identifier, as the manifest declares it.
    static let paneID = PaneID(rawValue: "com.moonwink.tingra.notes.pane")

    /// The settings pane's identifier, as the manifest declares it.
    static let settingsPaneID = PaneID(rawValue: "com.moonwink.tingra.notes.settings")

    /// Creates the extension; the system calls this once per process.
    required init() {}

    /// The notes editor for the pane, the font-size control for settings.
    @ViewBuilder
    func pane(for id: PaneID) -> some View {
        if id == Self.settingsPaneID {
            NotesSettingsView()
        } else {
            NotesPaneView()
        }
    }

    /// "Show Notes": the app has already revealed the pane and emitted the
    /// `tap`; the plug-in's own event is the command's effect.
    func perform(_ command: CommandID, using connection: PlugInConnection) async throws {
        switch command.rawValue {
        case "show":
            await connection.event("notes.shown")
        default:
            await connection.error("notes.unknownCommand", params: ["command": .string(command.rawValue)])
        }
    }
}
