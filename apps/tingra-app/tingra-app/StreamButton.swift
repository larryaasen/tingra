//
//  StreamButton.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// The Start Streaming / Stop Streaming control, in the main window's toolbar
/// beside ``RecordButton``.
///
/// It followed Record out of its panel on 2026-09-06, for the same reason: it
/// is the other action an operator reaches for under pressure, and the foot
/// of a scrolling column is the one place it can be out of sight. The
/// destination rows and the session status stay in the streaming panel; what
/// the button needs from them — the stream keys typed into the rows — arrives
/// as a value, collected by ``ContentView`` at the click, so the keys stay
/// view-local and never enter the model, the document, or an event
/// (ARCHITECTURE.md, "Streaming the program").
///
/// ⌘G (``ProductionShortcut/goLive``) binds here — Ecamm Live's own Go Live
/// assignment — bound to the control rather than to a menu item so it carries
/// the keys and the same disabled rule: nothing to stream to, nothing to
/// start. The label carries the word as well as the symbol, as Record's does,
/// so the two red toolbar states cannot read as one: while on air the antenna
/// is drawn red — the on-air convention, the tally's own color — beside the
/// words "Stop Streaming", colored on the image itself for the reason
/// ``RecordButton`` records (a toolbar's tint never reaches the glyph).
struct StreamButton: View {
    /// The engine model the control drives.
    let model: EngineModel

    /// Each destination's stream key, by destination id, as typed into the
    /// panel's rows — handed to ``EngineModel/startStreaming(keys:)`` and
    /// nowhere else.
    let keys: [ProjectDestinationID: String]

    var body: some View {
        Button {
            if model.isStreaming {
                model.eventBus.tap("streamStop.button", domain: .output)
                Task { await model.stopStreaming() }
            } else {
                model.eventBus.tap(
                    "streamStart.button",
                    domain: .output,
                    params: ["destinations": .int(model.destinations.count(where: \.isStreamable))]
                )
                let keys = keys
                Task { await model.startStreaming(keys: keys) }
            }
        } label: {
            if model.isStreaming {
                Label {
                    Text("Stop Streaming", comment: "Button that takes the program off air")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.red)
                }
            } else {
                Label {
                    Text("Start Streaming", comment: "Button that puts the program on air")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(!model.isStreaming && !model.hasStreamableDestination)
        .keyboardShortcut(ProductionShortcut.goLive.shortcut)
    }
}
