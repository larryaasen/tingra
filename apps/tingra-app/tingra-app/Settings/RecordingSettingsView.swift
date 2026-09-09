//
//  RecordingSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus
import TingraPlugInKit
import TingraRecordingPlugIns
import UniformTypeIdentifiers

/// The Recording settings pane: where the program is written, the container
/// it is muxed into, how much room the volume still holds, and the rolling
/// status (ARCHITECTURE.md, "Recording in the app"). The Record control
/// itself is in the main window's toolbar (``RecordButton``).
///
/// It was the recording panel at the foot of the main window's column until
/// 2026-09-08, when it moved here with the streaming panel: the folder and
/// the format are set up before a show, not reached for during one, and the
/// column they left is the one the operator works the show from. A grouped
/// `Form` on the Logging pane's shape, with the control on the trailing edge
/// of each labeled row.
///
/// Its own pane beside the Streaming one rather than a section inside it,
/// because the two are independent sessions: stopping the stream leaves a
/// recording rolling, and stopping a recording leaves the stream on air. The
/// interface has to say so.
struct RecordingSettingsView: View {
    /// The engine model the controls drive.
    let model: EngineModel

    /// Whether the folder chooser is open.
    @State private var isChoosingFolder = false

    /// The elapsed-time ticker, running only while a recording is rolling —
    /// a once-a-second redraw of a label, never a poll of engine state.
    private var timeline: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            elapsedLabel(at: context.date)
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        model.eventBus.tap("recordingFolder.button", domain: .output)
                        isChoosingFolder = true
                    } label: {
                        Text("Choose Folder…", comment: "Button that picks the folder recordings are written to")
                    }
                    .disabled(model.isRecording)
                } label: {
                    Text(
                        "Folder",
                        comment: "Recording settings: label of the row naming the folder recordings are written to")
                    Text(AppDataStore.abbreviatedPath(of: model.recordingFolder))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Picker(selection: containerSelection) {
                    ForEach(RecordingFile.Container.allCases, id: \.self) { container in
                        Text(verbatim: ".\(container.rawValue)").tag(container)
                    }
                } label: {
                    Text("Format", comment: "Recording container format picker label")
                }
                .pickerStyle(.menu)
                .disabled(model.isRecording)

                capacityRow
            } header: {
                Text("Recording File", comment: "Recording settings: heading over the folder, format, and room rows")
            } footer: {
                Text(
                    "Recordings are written to this folder, each named for the moment it starts. Record (⌘R) is in the main window's toolbar.",
                    comment: "Recording settings: footer explaining where recordings go and where the Record button is"
                )
            }

            Section {
                LabeledContent {
                    statusLabel
                } label: {
                    Text(
                        "Status", comment: "Streaming and Recording settings: label of the row showing the live status")
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            // The operator chooses a location; the app never types a path for
            // them (HIG). A cancelled or failed choice leaves the folder as it
            // was.
            guard case .success(let folder) = result else { return }
            model.setRecordingFolder(folder)
        }
    }

    /// How much recording the chosen volume still holds, in the unit the
    /// operator decides in — the same reading the pre-flight check refuses on,
    /// so the number shown and the number enforced cannot disagree. Absent
    /// while the volume cannot be measured.
    @ViewBuilder private var capacityRow: some View {
        if let capacity = model.recordingCapacity,
            let seconds = capacity.recordableSeconds(at: model.recordingConfiguration)
        {
            LabeledContent {
                Text(
                    verbatim: Duration.seconds(seconds)
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                )
                .foregroundStyle(capacity.hasRoom(for: model.recordingConfiguration) ? Color.primary : Color.red)
            } label: {
                Text(
                    "Room Left",
                    comment: "Recording settings: label of the row showing how much recording time the volume holds")
            }
        }
    }

    /// The container picker's binding, reporting its own tap so a format
    /// change is traceable separately from the folder choice.
    private var containerSelection: Binding<RecordingFile.Container> {
        Binding(
            get: { model.recordingContainer },
            set: { container in
                model.eventBus.tap(
                    "recordingFormat.picker",
                    domain: .output,
                    params: ["container": .string(container.rawValue)]
                )
                model.setRecordingContainer(container)
            }
        )
    }

    /// The live recording status, rendered from ``EngineModel/RecordingStatus``.
    ///
    /// The rolling state carries the conventional red record dot **with** its
    /// label: red already means on-air in the main window (the tally border,
    /// the program badge), and the word is what keeps two different reds from
    /// reading as one thing.
    @ViewBuilder private var statusLabel: some View {
        switch model.recordingStatus {
        case .idle:
            Text("Idle", comment: "Recording status: not recording")
                .foregroundStyle(.secondary)
        case .starting:
            Text("Starting…", comment: "Recording status: the file is being opened")
                .foregroundStyle(.orange)
        case .recording:
            timeline
        case .finalizing:
            Text("Finishing…", comment: "Recording status: the file is being closed so it is playable")
                .foregroundStyle(.orange)
        case .error(let message):
            Text("Error", comment: "Recording status: the recording could not start or could not continue")
                .foregroundStyle(.red)
                .help(message)
        }
    }

    /// The rolling label: the record dot, the elapsed time, and the file name.
    ///
    /// - Parameter date: The current moment, from the timeline.
    /// - Returns: The label.
    @ViewBuilder private func elapsedLabel(at date: Date) -> some View {
        HStack(spacing: 6) {
            Text("● Recording", comment: "Recording status: the program is being written to a file")
                .foregroundStyle(.red)
                .fontWeight(.semibold)
            if let started = model.recordingStartedAt {
                Text(
                    verbatim: Duration.seconds(max(0, date.timeIntervalSince(started)))
                        .formatted(.time(pattern: .hourMinuteSecond))
                )
                .foregroundStyle(.secondary)
                .font(.callout)
                .monospacedDigit()
            }
            if let url = model.recordingURL {
                Text(verbatim: url.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
