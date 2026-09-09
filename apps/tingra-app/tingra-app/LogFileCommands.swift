//
//  LogFileCommands.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraEventBus

/// The Help menu's Share Log File… item — the Logging settings pane's share
/// action within reach of an operator who has been asked for a log and does
/// not know where to look, the Auto Care Plus mirror on the Mac
/// (ARCHITECTURE.md, "The log file and the Logging settings pane").
///
/// `CommandGroup(after: .help)` puts it beneath the system's own Tingra Help
/// item, the first item the app adds to that menu. It takes the same dated
/// snapshot the pane shares (``LogFileModel/snapshot()``) and hands it to the
/// system share picker, anchored to the key window's content — AppKit where
/// SwiftUI does not reach, since a `ShareLink` cannot sit in a menu. The
/// click is reported as a `tap` (`logShare.menuItem`) before anything else.
/// A snapshot that cannot be taken is recorded as the model's `log.snapshot`
/// error and shows no picker; the log is never empty while the app runs — its
/// first line is `app.launched`, and this very click adds one — so that path
/// is an unwritable file, not an empty one.
struct LogFileCommands: Commands {
    /// The engine model, for the command's `tap` and its log file model.
    let model: EngineModel

    /// The one Help-menu item.
    var body: some Commands {
        CommandGroup(after: .help) {
            Button {
                model.eventBus.tap("logShare.menuItem", domain: .platform)
                share()
            } label: {
                Text("Share Log File…", comment: "Help menu item that shares a copy of the log file")
            }
        }
    }

    /// Takes the snapshot and shows the share picker over the key window.
    private func share() {
        guard
            let snapshot = model.logFileModel.snapshot(),
            let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow,
            let view = window.contentView
        else { return }
        NSSharingServicePicker(items: [snapshot]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
