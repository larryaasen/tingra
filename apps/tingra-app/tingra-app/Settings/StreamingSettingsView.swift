//
//  StreamingSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The Streaming settings pane: the destinations the program fans out to, one
/// section each with Add Destination after them (``DestinationListView``),
/// and the stream's live status (ARCHITECTURE.md, "Streaming the program",
/// "Multiple destinations"). The Start/Stop control itself is in the main
/// window's toolbar (``StreamButton``).
///
/// It was the streaming panel at the foot of the main window's column until
/// 2026-09-08, when it moved here with the recording panel: destinations are
/// set up before a show, not reached for during one, and the column they
/// left is the one the operator works the show from. Moving the rows out of
/// the window that holds Start Streaming is what changed where the stream
/// keys live. They were view-local field text, collected by the button at the
/// click — and a click in one window cannot read fields in another — so each
/// key is now filed in the Keychain as it is typed and read back at Start
/// (``EngineModel/setStreamKey(_:for:)``), the one place a key was ever meant
/// to live.
///
/// The status section stays with the destinations rather than going back to
/// the main window: the status bar there already answers "am I on air", and
/// what this pane adds is the per-destination reading the bar cannot carry —
/// which leg is reconnecting, which was refused — beside the destination it
/// belongs to.
struct StreamingSettingsView: View {
    /// The engine model owning the destinations and the stream session.
    let model: EngineModel

    var body: some View {
        Form {
            DestinationListView(model: model)

            Section {
                LabeledContent {
                    streamStatusLabel
                } label: {
                    Text(
                        "Status", comment: "Streaming and Recording settings: label of the row showing the live status")
                }
            } footer: {
                Text(
                    "The program streams to every enabled destination at once. Start Streaming (⌘G) is in the main window's toolbar; stream keys are kept in the Keychain, never in the project file.",
                    comment: "Streaming settings: footer under the status row"
                )
            }
        }
        .formStyle(.grouped)
    }

    /// The live stream status, rendered from ``EngineModel/StreamStatus`` — the
    /// event-driven state the session reports on the bus.
    @ViewBuilder private var streamStatusLabel: some View {
        switch model.streamStatus {
        case .idle:
            Text("Idle", comment: "Stream status: not streaming")
                .foregroundStyle(.secondary)
        case .starting:
            Text("Connecting…", comment: "Stream status: connecting to the destination")
                .foregroundStyle(.orange)
        case .live:
            HStack(spacing: 6) {
                Text("● Live", comment: "Stream status: the program is on air")
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
                if let stats = model.streamStats {
                    Text(verbatim: "\(stats.bitrateKbps) kbps · \(stats.fps) fps")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .monospacedDigit()
                }
            }
        case .reconnecting(let attempt, let maxAttempts):
            (Text("Reconnecting…", comment: "Stream status: a reconnect attempt is in flight")
                + Text(verbatim: " \(attempt)/\(maxAttempts)"))
                .foregroundStyle(.orange)
        case .stopped:
            Text("Stopped", comment: "Stream status: the stream ended cleanly")
                .foregroundStyle(.secondary)
        case .error(let message):
            Text("Error", comment: "Stream status: the stream ended on a failure")
                .foregroundStyle(.red)
                .help(message)
        }
    }
}
