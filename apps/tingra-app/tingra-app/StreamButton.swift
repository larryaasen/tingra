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
/// destination rows and the session status followed on 2026-09-08 — into the
/// Streaming settings pane (``StreamingSettingsView``), another window
/// entirely — which is why the button takes nothing but the model: the stream
/// keys it once received as a value collected from the rows at the click are
/// read back from the Keychain by ``EngineModel/startStreaming()`` instead,
/// filed there as they are typed. The keys still never enter the model, the
/// document, or an event (ARCHITECTURE.md, "Streaming the program").
///
/// ⌘G (``ProductionShortcut/goLive``) binds here — Ecamm Live's own Go Live
/// assignment — bound to the control rather than to a menu item so it carries
/// the keys and the same disabled rule: nothing to stream to, nothing to
/// start. The label carries the word as well as the symbol, as Record's does,
/// so the two red toolbar states cannot read as one: while on air the antenna
/// is drawn red — the on-air convention, the tally's own color — beside the
/// words "Stop Streaming", colored on the image itself for the reason
/// ``RecordButton`` records (a toolbar's tint never reaches the glyph).
///
/// **While the stream is stopping it reads Stopping… and cannot be clicked**
/// (2026-09-26). Closing every destination's connection takes a few seconds,
/// and until then the button kept saying Stop Streaming, so a click looked
/// ignored and invited a second one. The label changes the moment the click
/// lands (``EngineModel/stopStreaming()`` sets the state before asking the
/// session to stop), the antenna stays red because the program may still be
/// reaching viewers until the connections close, and the button is disabled —
/// ⌘G with it — until the stream has ended and it reads Start Streaming.
struct StreamButton: View {
    /// The engine model the control drives.
    let model: EngineModel

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
                Task { await model.startStreaming() }
            }
        } label: {
            if model.isStoppingStream {
                Label {
                    Text("Stopping…", comment: "Stream status: Stop was clicked and the connections are being closed")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.red)
                }
            } else if model.isStreaming {
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
        .disabled(model.isStoppingStream || (!model.isStreaming && !model.hasStreamableDestination))
        .help(helpText)
        .keyboardShortcut(ProductionShortcut.goLive.shortcut)
    }

    /// The button's tooltip — above all, **why it is disabled** when it is.
    ///
    /// Added 2026-09-26, after a destination named "Twitch" with its key
    /// filed but its URL left blank kept Start Streaming gray with nothing
    /// saying why: a disabled control should name what it is waiting for, and
    /// the thing it waits for is in another window (DESTINATIONS.md,
    /// "Destination templates").
    private var helpText: Text {
        if model.isStoppingStream {
            Text(
                "Closing the connection to every destination",
                comment: "Tooltip for the stream button while the stream is stopping"
            )
        } else if model.isStreaming {
            Text("Stop streaming to every destination", comment: "Tooltip for Stop Streaming while on air")
        } else if model.hasStreamableDestination {
            Text("Stream the program to every enabled destination", comment: "Tooltip for Start Streaming")
        } else {
            Text(
                "To start streaming, add a destination with an rtmp://, rtmps://, or srt:// URL and turn it on in Settings ▸ Streaming.",
                comment:
                    "Tooltip for Start Streaming while it is disabled because no enabled destination has a usable URL"
            )
        }
    }
}
