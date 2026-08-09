//
//  StatusBarView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The window's status bar: whether the program is being **recorded** and
/// whether it is being **streamed**, across the bottom of the window.
///
/// **Why a status bar rather than the panels that already say this.** The main
/// window's recording and streaming panels are at the bottom of a scrolling
/// column of eight surfaces, so the two facts an operator must never misread —
/// am I on air, am I recording — are exactly the two that scroll out of sight
/// while they work the switcher. The multiview window never had them at all.
/// A status bar is where macOS puts a persistent readout of what a window's
/// document is doing, and pinning it outside the scroll view is the whole
/// point: it is drawn once per window and never moves.
///
/// It carries **status only, no controls**. A bar that is always on screen is
/// also always one stray click from whatever it holds, and the two actions it
/// would hold are the two that go out to viewers. Record and Start Streaming
/// stay in their panels, where they sit beside the destination rows and the
/// folder they act on, and where ⌘R and ⌘G already reach them
/// (``ProductionShortcut``).
///
/// Shared by the main window and the multiview window, so a reading cannot
/// differ between the two surfaces — the rule ``MonitorTile`` follows for
/// tiles. It draws nothing at all when the operator has turned it off in
/// General settings (``StatusBarModel``), which is what lets both windows
/// attach it unconditionally as a bottom safe-area inset.
struct StatusBarView: View {
    /// The engine model, read only: the bar reports and never acts.
    let model: EngineModel

    /// Whether the bar is shown.
    let statusBar: StatusBarModel

    /// The bar's height — the standard macOS status bar's, near enough that it
    /// reads as one rather than as a row of controls.
    private static let height: CGFloat = 24

    /// The inset before the first reading, matching the padding around the
    /// production surfaces (``ContentView/columnPadding``) so the readings line
    /// up with the panel headings above them rather than sitting a few points
    /// off from everything else in the column.
    ///
    /// It is what the bar looks like with the **sidebar collapsed** that
    /// settles the value: the detail column then starts at the window's own
    /// edge, and a bar hugging that edge reads as text that fell off the
    /// layout. With the sidebar open the inset is measured from the split
    /// view's divider instead, which is the same relationship the content has.
    private static let horizontalPadding = ContentView.columnPadding

    /// The bar, or nothing when it is turned off.
    ///
    /// The separator rides **above** the material rather than being drawn by
    /// it: a status bar is a strip taken off the bottom of the content, and the
    /// hairline is what says where the content ended.
    @ViewBuilder var body: some View {
        if statusBar.isVisible {
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 10) {
                    // Recording first: it is the reading with something to
                    // lose. A stream that drops can be restarted; a take that
                    // was never recorded is gone.
                    recordingReading

                    Divider()
                        .frame(height: 12)

                    streamingReading

                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(height: Self.height)
            }
            .background(.bar)
        }
    }

    /// The recording reading: what the local file is doing, with the elapsed
    /// time while one is rolling.
    @ViewBuilder private var recordingReading: some View {
        let item = StatusBarItem.recording(model.recordingStatus)
        switch model.recordingStatus {
        case .idle:
            reading(item, label: Text("Not recording", comment: "Status bar reading: nothing is being recorded"))
        case .starting:
            reading(item, label: Text("Starting…", comment: "Recording status: the file is being opened"))
        case .recording:
            reading(
                item,
                label: Text("Recording", comment: "Status bar reading: the program is being written to a file")
            ) {
                elapsedTime
            }
        case .finalizing:
            reading(
                item,
                label: Text("Finishing…", comment: "Recording status: the file is being closed so it is playable")
            )
        case .error(let message):
            reading(
                item,
                label: Text(
                    "Recording error",
                    comment: "Status bar reading: the recording could not start or could not continue"
                ),
                help: message
            )
        }
    }

    /// The streaming reading: what the session is doing, with the delivery
    /// counters while it is live.
    @ViewBuilder private var streamingReading: some View {
        let item = StatusBarItem.streaming(model.streamStatus)
        switch model.streamStatus {
        case .idle, .stopped:
            reading(item, label: Text("Not streaming", comment: "Status bar reading: the program is not on air"))
        case .starting:
            reading(item, label: Text("Connecting…", comment: "Stream status: connecting to the destination"))
        case .live:
            reading(item, label: Text("Live", comment: "Status bar reading: the program is on air")) {
                if let stats = model.streamStats {
                    Text(verbatim: "\(stats.bitrateKbps) kbps · \(stats.fps) fps")
                        .monospacedDigit()
                }
            }
        case .reconnecting(let attempt, let maxAttempts):
            reading(item, label: Text("Reconnecting…", comment: "Stream status: a reconnect attempt is in flight")) {
                Text(verbatim: "\(attempt)/\(maxAttempts)")
                    .monospacedDigit()
            }
        case .error(let message):
            reading(
                item,
                label: Text(
                    "Streaming error",
                    comment: "Status bar reading: the stream could not start or could not continue"
                ),
                help: message
            )
        }
    }

    /// How long the current recording has been rolling.
    ///
    /// A once-a-second redraw of a label — the ``RecordingPanel`` timeline,
    /// and never a poll of engine state (CLAUDE.md): the start instant comes
    /// from the model, and only the *clock* ticks. It exists only while a
    /// recording does, so an idle app redraws nothing.
    private var elapsedTime: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let started = model.recordingStartedAt {
                Text(
                    verbatim: Duration.seconds(max(0, context.date.timeIntervalSince(started)))
                        .formatted(.time(pattern: .hourMinuteSecond))
                )
                .monospacedDigit()
            }
        }
    }

    /// One reading on the bar: its symbol, its label, and any detail beside
    /// it, tinted and weighted by what the lamp reads.
    ///
    /// - Parameters:
    ///   - item: The reading's lamp and symbol (``StatusBarItem``).
    ///   - label: What the reading says.
    ///   - help: The tooltip, used to carry an error's developer-facing
    ///     message the way the panels do. Empty for the readings that have
    ///     nothing more to say, which shows no tooltip.
    ///   - detail: The secondary text beside the label — an elapsed time, a
    ///     bitrate — or nothing.
    /// - Returns: The reading.
    private func reading<Detail: View>(
        _ item: StatusBarItem,
        label: Text,
        help: String = "",
        @ViewBuilder detail: () -> Detail = { EmptyView() }
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: item.systemImage)
            label
            detail()
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(item.light.tint)
        .fontWeight(item.light.isProminent ? .semibold : .regular)
        .help(help)
        // One reading is one thing VoiceOver should say — "Recording,
        // 00:01:23" — rather than a symbol, a word, and a number in a row.
        .accessibilityElement(children: .combine)
    }
}
