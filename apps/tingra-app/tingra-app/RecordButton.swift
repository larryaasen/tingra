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
///
/// **While the file is being closed it reads Finishing… and cannot be
/// clicked** (2026-10-13), the rule ``StreamButton`` follows while a stream
/// stops. Until then the button read Record the moment Stop Recording was
/// clicked, though a new recording cannot start before the last one's file is
/// finalized, so a click on it did nothing. The dot is no longer red: nothing
/// more is being captured. ⌘R is disabled with the button.
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
            if model.isFinishingRecording {
                Label {
                    Text("Finishing…", comment: "Recording status: the file is being closed so it is playable")
                } icon: {
                    Image(systemName: "record.circle")
                }
            } else if model.isRecording {
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
        .disabled(model.isFinishingRecording)
        .keyboardShortcut(ProductionShortcut.record.shortcut)
    }
}
