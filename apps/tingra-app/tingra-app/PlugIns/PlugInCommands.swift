//
//  PlugInCommands.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraAppPlugInKit
import TingraEventBus
import TingraPlugInKit

/// The **Plug-ins** menu: one submenu per plug-in with commands, each item a
/// command the plug-in's manifest declared — rendered before the extension
/// has ever run, the way every Mac host groups third-party additions
/// (PLUGINS.md, Decision 6). Absent while no plug-in has a command.
///
/// Every item emits its `tap` first — named for the plug-in and command,
/// under the plug-in's domain — then hands the command to the host, which
/// reveals the pane the command names and forwards it to the extension; a
/// window the command names is opened here, before the hand-off, because
/// `openWindow` is an environment action only the menu can reach. The
/// command's own effect is the plug-in's event, so the convention from
/// EVENTS.md holds for authors who have never read EVENTS.md.
struct PlugInCommands: Commands {
    /// The engine model the `tap` is reported through.
    let model: EngineModel

    /// The host whose commands are listed.
    let host: AppPlugInHost

    /// Opens a plug-in's window.
    @Environment(\.openWindow) private var openWindow

    /// The menu.
    var body: some Commands {
        if !host.commands.commands.isEmpty {
            CommandMenu(Text("Plug-ins", comment: "Title of the Plug-ins menu, one submenu per plug-in with commands"))
            {
                ForEach(host.commands.plugIns, id: \.id) { plugIn in
                    Menu {
                        ForEach(host.commands.commands(for: plugIn.id)) { command in
                            PlugInCommandItem(command: command, model: model, host: host) { window in
                                openWindow(id: TingraApp.plugInWindowID, value: window)
                            }
                        }
                    } label: {
                        Text(verbatim: plugIn.name)
                    }
                }
            }
        }
    }
}

/// One command's menu item, with its shortcut when the manifest declares a
/// usable one.
struct PlugInCommandItem: View {
    /// The command.
    let command: RegisteredCommand

    /// The engine model the `tap` is reported through.
    let model: EngineModel

    /// The host the command is handed to.
    let host: AppPlugInHost

    /// Opens the window a command names, or brings it forward.
    let openWindow: (PaneID) -> Void

    /// The item.
    var body: some View {
        let button = Button {
            model.eventBus.tap(command.tapName, domain: EventDomain(command.plugIn.rawValue))
            // Only a window the plug-in itself declared: a command cannot
            // open another plug-in's window by naming its id.
            if let window = command.descriptor.showsWindow, host.panes.window(window)?.plugIn == command.plugIn {
                openWindow(window)
            }
            Task { await host.invoke(command) }
        } label: {
            Text(verbatim: command.descriptor.title)
        }
        if let shortcut = command.descriptor.shortcut.flatMap(PlugInShortcut.keyboardShortcut) {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}
