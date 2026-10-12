//
//  StreamHistorySection.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus
import TingraHost

/// The Streaming settings pane's stream history: the figures over every
/// streamed session, the sessions themselves newest first, and the action
/// that clears them (ARCHITECTURE.md, "Stream history").
///
/// It sits under the destinations and the live status because it answers the
/// question that follows them — not "am I on air" but "when was I, to where,
/// and for how long". The newest sessions are listed and the rest are behind
/// Show All, so a long history does not push the destinations off a pane the
/// operator opens to edit them.
struct StreamHistorySection: View {
    /// How many sessions are listed before Show All.
    static let recentLimit = 5

    /// The engine model owning the stream history.
    let model: EngineModel

    /// Whether every session is listed rather than the newest few.
    @State private var showsAll = false

    /// Whether the clear confirmation is showing.
    @State private var isClearConfirmationPresented = false

    /// The stream history.
    private var history: StreamHistoryModel { model.streamHistory }

    /// The sessions the section lists: newest first, cut to the newest few
    /// until Show All.
    private var listedEntries: [StreamHistoryEntry] {
        let newestFirst = Array(history.entries.reversed())
        return showsAll ? newestFirst : Array(newestFirst.prefix(Self.recentLimit))
    }

    /// The section.
    var body: some View {
        Section {
            LabeledContent {
                Text(history.summary.sessionCount.formatted())
                    .monospacedDigit()
            } label: {
                Text("Sessions", comment: "Stream history: label of the row counting the streamed sessions")
            }
            LabeledContent {
                Text(StreamHistoryFormat.duration(history.summary.totalDuration))
                    .monospacedDigit()
            } label: {
                Text(
                    "Total Time on Air",
                    comment: "Stream history: label of the row summing how long every session was on air")
            }

            ForEach(listedEntries) { entry in
                StreamHistoryRow(entry: entry, isOnAir: history.isOnAir(entry), eventBus: model.eventBus)
            }

            if history.entries.count > Self.recentLimit {
                Button {
                    model.eventBus.tap(
                        "streamHistoryShowAll.button", domain: .output, params: ["showsAll": .bool(!showsAll)])
                    showsAll.toggle()
                } label: {
                    if showsAll {
                        Text(
                            "Show Recent Sessions",
                            comment: "Stream history: button that lists only the newest sessions")
                    } else {
                        Text(
                            "Show All \(history.entries.count) Sessions",
                            comment: "Stream history: button that lists every session; the placeholder is how many")
                    }
                }
                .buttonStyle(.link)
            }

            LabeledContent {
                Button(role: .destructive) {
                    model.eventBus.tap("streamHistoryClear.button", domain: .output)
                    isClearConfirmationPresented = true
                } label: {
                    Text("Clear…", comment: "Logging settings: button that opens the clear confirmation")
                }
                .disabled(history.isEmpty)
            } label: {
                Text(
                    "Clear Stream History",
                    comment: "Stream history: label of the clear row, and the confirmation's button")
                Text(
                    "Removes every session listed here. The next session is session 1 again.",
                    comment: "Stream history: description under the clear row")
            }
            .alert(
                Text(
                    "Clear the stream history?", comment: "Confirmation alert title before clearing the stream history"),
                isPresented: $isClearConfirmationPresented
            ) {
                Button(role: .destructive) {
                    model.eventBus.tap("streamHistoryClearConfirm.button", domain: .output)
                    history.clear()
                } label: {
                    Text(
                        "Clear Stream History",
                        comment: "Stream history: label of the clear row, and the confirmation's button")
                }
                Button(role: .cancel) {
                    model.eventBus.tap("streamHistoryClearCancel.button", domain: .output)
                } label: {
                    Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
                }
            } message: {
                Text(
                    "This removes the record of every streamed session and resets the totals. Recordings and the log file are not affected. This cannot be undone.",
                    comment: "Confirmation alert message before clearing the stream history"
                )
            }
        } header: {
            Text(
                "Stream History",
                comment: "The record of streamed sessions — the Data settings kind and the Streaming settings heading")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Each time the program goes on air, Tingra records the session: where it streamed to, when it started and ended, and the program format. The history is kept on this Mac.",
                    comment: "Stream history: footer explaining what is recorded"
                )
                if let failure = history.clearFailure {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

/// One streamed session's row, on one line: its number, where it streamed
/// to, when it ran, the program format, and how long it was on air.
///
/// One line per session (Larry, 2026-10-11; three until then) so the list
/// reads as a table and a long history stays short. The destinations are the
/// part that gives way when the pane is narrow, truncating while the figures
/// keep their width, and the row's tooltip carries everything in full —
/// including how the session ended, which a marker flags when it was not the
/// operator's stop. Clicking the marker shows how the session ended, and
/// only that, in a popover.
struct StreamHistoryRow: View {
    /// The session this row shows.
    let entry: StreamHistoryEntry

    /// Whether the session is on air now.
    let isOnAir: Bool

    /// The host's event bus, for the marker's `tap`.
    let eventBus: EventBus

    /// Whether the marker's popover is showing.
    @State private var isDetailPresented = false

    /// The row.
    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(entry.number)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
                .accessibilityLabel(Text(title))
            Text(StreamHistoryFormat.destinations(of: entry))
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let ending {
                Button {
                    eventBus.tap(
                        "streamHistoryEnding.button", domain: .output, params: ["session": .int(entry.number)])
                    isDetailPresented.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text("How this session ended", comment: "Stream history: accessibility label of a row's marker")
                )
                .popover(isPresented: $isDetailPresented, arrowEdge: .bottom) {
                    // Only how the session ended: the rest is on the row.
                    // The row's one-line limit reaches a popover through the
                    // environment, so it is lifted here.
                    Text(ending)
                        .lineLimit(nil)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding()
                }
            }
            Group {
                Text(StreamHistoryFormat.period(of: entry, isOnAir: isOnAir))
                Text(StreamHistoryFormat.programFormat(of: entry))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
            length
                .fixedSize()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .lineLimit(1)
        .help(Text(tooltip))
    }

    /// The session's title, as the tooltip and VoiceOver name it.
    private var title: LocalizedStringResource {
        LocalizedStringResource(
            "Session \(entry.number)", comment: "Stream history: a session's title; the placeholder is its number")
    }

    /// Everything the row says, in full and one fact to a line: what the
    /// narrow row truncates, and how the session ended when that is worth
    /// saying.
    private var tooltip: String {
        var lines = [String(localized: title)]
        if !entry.destinations.isEmpty {
            lines.append(StreamHistoryFormat.destinations(of: entry))
        }
        lines.append(StreamHistoryFormat.period(of: entry, isOnAir: isOnAir))
        lines.append(StreamHistoryFormat.programFormat(of: entry))
        if let ending {
            lines.append(String(localized: ending))
        }
        return lines.joined(separator: "\n")
    }

    /// The trailing figure: “On Air” for the session running now, else the
    /// time on air — counted to the last moment it was known to be on air
    /// for a session whose end was never seen — or a dash for one cut off
    /// before it had reported anything.
    @ViewBuilder private var length: some View {
        if isOnAir {
            Text("On Air", comment: "Stream history: shown in place of a length for the session running now")
                .foregroundStyle(.red)
                .fontWeight(.semibold)
        } else if let duration = entry.duration {
            Text(StreamHistoryFormat.duration(duration))
                .monospacedDigit()
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
        }
    }

    /// The line saying how the session ended, when that is worth saying: a
    /// stop the operator asked for needs no remark.
    private var ending: LocalizedStringResource? {
        switch entry.endReason {
        case .connectionLost:
            LocalizedStringResource(
                "Ended when every destination was lost",
                comment: "Stream history: remark on a session that ended because the connections dropped")
        case .appQuit:
            LocalizedStringResource(
                "Ended when Tingra quit", comment: "Stream history: remark on a session cut off by quitting the app")
        case .stopped:
            nil
        case nil:
            if isOnAir {
                nil
            } else if entry.lastOnAirAt != nil {
                LocalizedStringResource(
                    "Ended unexpectedly; the end shown is when it was last known to be on air",
                    comment:
                        "Stream history: remark on a session whose end was never seen, as after a crash, shown with the last time it reported being on air"
                )
            } else {
                LocalizedStringResource(
                    "Ended unexpectedly; the end time was not recorded",
                    comment: "Stream history: remark on a session whose end was never seen, as after a crash")
            }
        }
    }
}
