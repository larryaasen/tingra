//
//  RecordingPanel.swift
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

/// The recording panel: where the program is written, how much room is left,
/// and the Record control (ARCHITECTURE.md, "Recording in the app").
///
/// Its own panel beside the streaming one rather than a checkbox inside it,
/// because the two are independent sessions: stopping the stream leaves a
/// recording rolling, and stopping a recording leaves the stream on air. The
/// interface has to say so.
struct RecordingPanel: View {
    /// The engine model the control drives.
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording", comment: "Section heading over the recording folder and Record control")
                .font(.headline)

            HStack(spacing: 12) {
                folderControls
                Spacer()
                statusLabel
                recordButton
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            // The operator chooses a location; the app never types a path for
            // them (HIG). A cancelled or failed choice leaves the folder as it
            // was.
            guard case .success(let folder) = result else { return }
            model.setRecordingFolder(folder)
        }
    }

    /// The folder, the container picker, and how much room is left.
    private var folderControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    model.eventBus.tap("recordingFolder.button", domain: .output)
                    isChoosingFolder = true
                } label: {
                    Text("Choose Folder…", comment: "Button that picks the folder recordings are written to")
                }
                .disabled(model.isRecording)

                Text(verbatim: model.recordingFolder.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .help(model.recordingFolder.path(percentEncoded: false))

                Picker(selection: containerSelection) {
                    ForEach(RecordingFile.Container.allCases, id: \.self) { container in
                        Text(verbatim: ".\(container.rawValue)").tag(container)
                    }
                } label: {
                    Text("Format", comment: "Recording container format picker label")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.isRecording)
            }

            capacityLabel
        }
    }

    /// How much recording the chosen volume still holds, in the unit the
    /// operator decides in — the same reading the pre-flight check refuses on,
    /// so the number shown and the number enforced cannot disagree.
    @ViewBuilder private var capacityLabel: some View {
        if let capacity = model.recordingCapacity,
            let seconds = capacity.recordableSeconds(at: model.recordingConfiguration)
        {
            let room = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            Text("\(room) of room left", comment: "How much recording time the chosen volume still holds")
                .font(.callout)
                .foregroundStyle(capacity.hasRoom(for: model.recordingConfiguration) ? Color.secondary : Color.red)
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

    /// The Record / Stop Recording control.
    private var recordButton: some View {
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
                Text("Stop Recording", comment: "Button that stops the local recording")
            } else {
                Text("Record", comment: "Button that starts recording the program to a local file")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .keyboardShortcut(ProductionShortcut.record.shortcut)
    }

    /// The live recording status, rendered from ``EngineModel/RecordingStatus``.
    ///
    /// The rolling state carries the conventional red record dot **with** its
    /// label: red already means on-air here (the tally border, the program
    /// badge), and the word is what keeps two different reds from reading as
    /// one thing.
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
