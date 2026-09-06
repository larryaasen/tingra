//
//  RecordButton.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The Record / Stop Recording control, in the main window's toolbar beside
/// ``StreamButton``.
///
/// It lived in the recording panel at the foot of the scrolling column until
/// 2026-09-06, beside the folder and format it acts on, which put the one
/// button an operator reaches for under pressure at the bottom of a column
/// that scrolls it out of sight. The toolbar is where a window's primary
/// actions belong (HIG, "Toolbars"), and where it is always on screen. The
/// folder, the format, and the rolling status stay in the panel
/// (``RecordingPanel``): they are set up before a show, not reached for
/// during one.
///
/// ⌘R (``ProductionShortcut/record``) binds here, so the shortcut moved with
/// the button. The label carries the word as well as the symbol on purpose:
/// red already means on air in this window, and "Stop Recording" in text is
/// what keeps a red toolbar glyph from reading as a streaming state.
///
/// **While recording, the symbol is a filled red record dot** — the one
/// indicator every recorder shares, from a tape deck's REC lamp to Apple's
/// Camera, Voice Memos, and QuickTime, all of which show red while capturing.
/// The dot is the state and the word beside it is the action. The color is
/// applied to the image itself rather than through `tint`, because a toolbar
/// draws its items' labels in its own monochrome style and a tint never
/// reaches the glyph.
struct RecordButton: View {
    /// The engine model the control drives.
    let model: EngineModel

    var body: some View {
        Button {
            if model.isRecording {
                model.eventBus.tap("recordStop.button", domain: .output)
                Task { await model.stopRecording() }
            } else {
                model.eventBus.tap("recordStart.button", domain: .output)
                Task { await model.startRecording() }
            }
        } label: {
            if model.isRecording {
                Label {
                    Text("Stop Recording", comment: "Button that stops the local recording")
                } icon: {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                Label {
                    Text("Record", comment: "Button that starts recording the program to a local file")
                } icon: {
                    Image(systemName: "record.circle")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .keyboardShortcut(ProductionShortcut.record.shortcut)
    }
}
