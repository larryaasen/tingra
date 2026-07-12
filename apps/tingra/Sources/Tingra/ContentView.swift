//
//  ContentView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// The main window: the program preview above the shot switcher, the
/// layer-tree editor, and the input pickers.
///
/// The pickers pick one camera and one display; the switcher takes the
/// chosen shot to program — a cut, or a dissolve when the switcher's
/// transition toggle is on (GLOSSARY.md, "Transition") — and manages the
/// preset's shots: an Add Shot button appends a new empty shot, and each
/// shot button's context menu duplicates, renames, or removes that shot
/// (ARCHITECTURE.md, "Shot management"); the editor
/// (``LayerTreeEditorView``) edits the selected shot's layer tree live;
/// the mixer panel (``MixerView``) mixes the audio inputs into the program
/// mix the streaming panel puts on air. This is the step-7 shape — the
/// remaining production surface (multiple presets) grows from here.
///
/// Every user action here reports its own `tap` event right where it's
/// executed — a picker's `onChange`, a button's action closure — rather than
/// the model doing it on the view's behalf (EVENTS.md, "The `tap`
/// convention"); `model.eventBus` is exposed for exactly this.
struct ContentView: View {
    /// The engine model, bindable so the pickers drive its selection.
    @Bindable var model: EngineModel

    /// The shot the rename dialog is editing, or `nil` while it is closed.
    /// View-local, like the layer editor's selection: which shot is being
    /// renamed is transient session state.
    @State private var shotBeingRenamed: Shot?

    /// The rename dialog's working text, prefilled with the shot's current
    /// name when the dialog opens.
    @State private var renameText = ""

    /// The stream-key field's working text. View-local and never handed to
    /// the model as observable state: the key flows straight into
    /// ``EngineModel/startStreaming(streamKey:)`` (which stores it in secure
    /// storage) and is prefilled from there — it never touches the project
    /// document or the event bus (ARCHITECTURE.md, "Streaming the program").
    @State private var streamKey = ""

    /// The window body: preview on top, controls beneath.
    var body: some View {
        VStack(spacing: 12) {
            ProgramPreviewView(relay: model.programRelay)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    Text("Program", comment: "Label over the live program preview")
                        .font(.caption.weight(.semibold))
                        .padding(6)
                        .background(.black.opacity(0.4), in: .capsule)
                        .foregroundStyle(.white)
                        .padding(8)
                }

            shotSwitcher

            LayerTreeEditorView(model: model)

            controls

            MixerView(model: model)

            streamingPanel
        }
        .padding()
        .task(id: model.destinationURL) {
            // Prefill the key field from secure storage for the current
            // destination — on launch (once the loaded URL arrives) and
            // whenever the URL changes.
            streamKey = model.storedStreamKey() ?? ""
        }
        .onChange(of: model.selectedCameraID) { _, newValue in
            let name = model.cameras.first { $0.id == newValue }?.name ?? "None"
            model.eventBus.tap(
                "camera.picker",
                domain: .capture,
                params: ["id": .string(newValue?.rawValue ?? "none"), "name": .string(name)]
            )
            Task { await model.reconfigure() }
        }
        .onChange(of: model.selectedDisplayID) { _, newValue in
            let name = model.displays.first { $0.id == newValue }?.name ?? "None"
            model.eventBus.tap(
                "display.picker",
                domain: .capture,
                params: ["id": .string(newValue?.rawValue ?? "none"), "name": .string(name)]
            )
            Task { await model.reconfigure() }
        }
    }

    /// The shot switcher: one button per available shot, taking it to program
    /// on tap (a dissolve when ``EngineModel/useDissolveTransition`` is on,
    /// otherwise a cut). The button for the shot currently on program is
    /// highlighted; its context menu duplicates, renames, or removes the
    /// shot, and the trailing Add Shot button appends a new empty one — the
    /// button stays available even when the preset has no shots, so the
    /// operator is never stranded on an empty switcher.
    private var shotSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(model.shots) { shot in
                    let isOnProgram = shot.id == model.activeShotID
                    Button(shot.name) {
                        model.eventBus.tap(
                            ProgramLayout.tapName(forShotID: shot.id),
                            domain: .composition,
                            params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
                        )
                        model.take(shot.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isOnProgram ? .accentColor : .gray)
                    .contextMenu {
                        shotCommands(for: shot)
                    }
                }

                Button {
                    model.eventBus.tap("shotAdd.button", domain: .composition)
                    model.addShot()
                } label: {
                    Label {
                        Text("Add Shot", comment: "Button adding a new empty shot to the preset")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }

            if !model.shots.isEmpty {
                Toggle(isOn: $model.useDissolveTransition) {
                    Text(
                        "Dissolve",
                        comment: "Toggle: use a dissolve transition for the next shot take, instead of a cut")
                }
                .toggleStyle(.checkbox)
                .onChange(of: model.useDissolveTransition) { _, newValue in
                    model.eventBus.tap(
                        "transition.toggle",
                        domain: .composition,
                        params: ["dissolve": .bool(newValue)]
                    )
                }
            }
        }
        .alert(
            Text("Rename Shot", comment: "Rename shot dialog title"),
            isPresented: isRenamePresented,
            presenting: shotBeingRenamed
        ) { shot in
            TextField(text: $renameText) {
                Text("Name", comment: "Rename shot dialog text field label")
            }
            Button {
                model.eventBus.tap(
                    "shotRenameConfirm.button",
                    domain: .composition,
                    params: ["shot": .string(shot.id.rawValue), "name": .string(renameText)]
                )
                model.renameShot(shot.id, to: renameText)
            } label: {
                Text("Rename", comment: "Rename shot dialog confirm button")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    "shotRenameCancel.button",
                    domain: .composition,
                    params: ["shot": .string(shot.id.rawValue)]
                )
            } label: {
                Text("Cancel", comment: "Rename shot dialog cancel button")
            }
        }
    }

    /// Whether the rename dialog is up — presented while a shot is being
    /// renamed, and clearing that shot when the dialog dismisses.
    private var isRenamePresented: Binding<Bool> {
        Binding {
            shotBeingRenamed != nil
        } set: { presented in
            if !presented { shotBeingRenamed = nil }
        }
    }

    /// One shot button's context menu: duplicate, rename, and remove that
    /// shot (ARCHITECTURE.md, "Shot management"). Remove is immediate — a
    /// destructive-role item, no confirmation: shots are quick to create,
    /// switch, and discard (GLOSSARY.md, "Shot").
    @ViewBuilder private func shotCommands(for shot: Shot) -> some View {
        Button {
            model.eventBus.tap(
                "shotDuplicate.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            model.duplicateShot(shot.id)
        } label: {
            Text("Duplicate", comment: "Shot context menu: duplicate this shot")
        }

        Button {
            model.eventBus.tap(
                "shotRename.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            renameText = shot.name
            shotBeingRenamed = shot
        } label: {
            Text("Rename…", comment: "Shot context menu: rename this shot")
        }

        Button(role: .destructive) {
            model.eventBus.tap(
                "shotRemove.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            Task { await model.removeShot(shot.id) }
        } label: {
            Text("Remove Shot", comment: "Shot context menu: remove this shot from the preset")
        }
    }

    /// The camera and display pickers.
    private var controls: some View {
        HStack(spacing: 20) {
            Picker(selection: $model.selectedCameraID) {
                Text("None", comment: "Picker option for no input selected").tag(InputID?.none)
                ForEach(model.cameras) { camera in
                    Text(camera.name).tag(InputID?.some(camera.id))
                }
            } label: {
                Text("Camera", comment: "Camera input picker label")
            }

            Picker(selection: $model.selectedDisplayID) {
                Text("None", comment: "Picker option for no input selected").tag(InputID?.none)
                ForEach(model.displays) { display in
                    Text(display.name).tag(InputID?.some(display.id))
                }
            } label: {
                Text("Display", comment: "Display input picker label")
            }
        }
        .pickerStyle(.menu)
    }

    /// The streaming panel: the RTMP(S) destination URL and stream key, the
    /// live status, and the Start/Stop control. Puts the program the operator
    /// already has on air (ARCHITECTURE.md, "Streaming the program") — video
    /// from the compositor, audio from the mixer panel's program mix; the
    /// destination fields lock while streaming.
    ///
    /// The stream key is a `SecureField` bound to view-local state, handed to
    /// the model only at Start — it is stored in the Keychain, never in the
    /// project document, an event, or a log.
    private var streamingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Streaming", comment: "Section heading over the destination and Start/Stop controls")
                .font(.headline)

            HStack(spacing: 8) {
                TextField(
                    text: $model.destinationURL,
                    prompt: Text("rtmp://server/app", comment: "Placeholder for the destination URL field")
                ) {
                    Text("Destination", comment: "Destination URL field label")
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.isStreaming)
                .onChange(of: model.destinationURL) { _, _ in model.destinationURLChanged() }

                SecureField(
                    text: $streamKey,
                    prompt: Text("Stream key", comment: "Placeholder for the stream key field")
                ) {
                    Text("Stream key", comment: "Stream key field label")
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.isStreaming)
            }

            HStack(spacing: 12) {
                Spacer()

                streamStatusLabel

                Button {
                    if model.isStreaming {
                        model.eventBus.tap("streamStop.button", domain: .output)
                        Task { await model.stopStreaming() }
                    } else {
                        model.eventBus.tap("streamStart.button", domain: .output)
                        let key = streamKey
                        Task { await model.startStreaming(streamKey: key) }
                    }
                } label: {
                    if model.isStreaming {
                        Text("Stop Streaming", comment: "Button that takes the program off air")
                    } else {
                        Text("Start Streaming", comment: "Button that puts the program on air")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isStreaming ? .red : .accentColor)
                .disabled(!model.isStreaming && model.destinationURL.isEmpty)
            }
        }
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
