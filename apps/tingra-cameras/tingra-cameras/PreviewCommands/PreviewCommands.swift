//
//  PreviewCommands.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The preview's commands in the menu bar: **Copy** in the Edit menu puts
/// the camera's current frame on the pasteboard, and **Cross Bars** in the
/// View menu shows lines through the centre of the preview. The preview's
/// context menu offers the same two (``SampleBufferHostView``).
///
/// Copy replaces the Edit menu's pasteboard group: the app has no text to
/// cut, paste, or select, so the frame is the only thing to copy.
struct PreviewCommands: Commands {
    /// The shared model the commands act on.
    let model: HardwareModel

    /// Copy in the Edit menu, Cross Bars in the View menu.
    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                model.copyFrame(from: "menu")
            }
            .keyboardShortcut("c")
            .disabled(!model.canCopyFrame)
        }
        CommandGroup(before: .sidebar) {
            Toggle(
                "Cross Bars",
                isOn: Binding {
                    model.showsCrossBars
                } set: { _ in
                    model.toggleCrossBars(from: "menu")
                }
            )
            Divider()
        }
    }
}
