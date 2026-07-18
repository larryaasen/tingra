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

/// The main window: the program preview above the preset switcher, the shot
/// switcher, the layer-tree editor, and the input pickers.
///
/// The preset switcher switches among — and manages — the project's presets
/// (ARCHITECTURE.md, "Multiple presets in the UI"): switching never
/// interrupts what is on program, an Add Preset button appends a new empty
/// preset, and each preset button's context menu duplicates, renames,
/// reorders (Move Left / Move Right), or removes it. The pickers pick one
/// camera and one display; the shot switcher takes the chosen shot to
/// program — each shot's own default transition while the switcher's
/// transition picker is on Default, or an explicit cut, dissolve, or wipe
/// (with its edge picker) as the override (GLOSSARY.md, "Transition") — and
/// manages the active preset's shots the same way, one level down
/// (ARCHITECTURE.md, "Shot management", "Shot and preset reordering"); the
/// editor (``LayerTreeEditorView``) edits the selected shot's layer tree
/// live; the mixer panel (``MixerView``) mixes the audio inputs into the
/// program mix the streaming panel puts on air. This is the step-7 shape —
/// the remaining production surfaces grow from here.
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

    /// The preset the rename dialog is editing, or `nil` while it is closed
    /// (see ``shotBeingRenamed`` — the same transient session state, one
    /// level up).
    @State private var presetBeingRenamed: Preset?

    /// The preset rename dialog's working text, prefilled with the preset's
    /// current name when the dialog opens.
    @State private var presetRenameText = ""

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

            presetSwitcher

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

    /// The preset switcher: one button per preset in the project, switching
    /// the switcher (never the program — a preset switch is seamless,
    /// GLOSSARY.md, "Preset") to it on tap. The active preset's button is
    /// highlighted — or none is, while a preset switch holds the outgoing
    /// shot on program from outside the pool; its context menu duplicates,
    /// renames, or removes the preset (Remove is disabled on the last
    /// remaining preset — a project always holds at least one), and the
    /// trailing Add Preset button appends a new empty one, mirroring the shot
    /// switcher one level up (ARCHITECTURE.md, "Multiple presets in the UI").
    private var presetSwitcher: some View {
        HStack(spacing: 8) {
            Text("Presets", comment: "Label leading the preset switcher row")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(model.presets) { preset in
                let isActive = preset.id == model.activePresetID
                Button(preset.name) {
                    model.eventBus.tap(
                        "preset.button",
                        domain: .composition,
                        params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
                    )
                    Task { await model.switchPreset(to: preset.id) }
                }
                .buttonStyle(.bordered)
                .tint(isActive ? .accentColor : nil)
                .contextMenu {
                    presetCommands(for: preset)
                }
            }

            Button {
                model.eventBus.tap("presetAdd.button", domain: .composition)
                model.addPreset()
            } label: {
                Label {
                    Text("Add Preset", comment: "Button adding a new empty preset to the project")
                } icon: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert(
            Text("Rename Preset", comment: "Rename preset dialog title"),
            isPresented: isPresetRenamePresented,
            presenting: presetBeingRenamed
        ) { preset in
            TextField(text: $presetRenameText) {
                Text("Name", comment: "Rename dialog text field label, for a shot or a preset")
            }
            Button {
                model.eventBus.tap(
                    "presetRenameConfirm.button",
                    domain: .composition,
                    params: ["preset": .string(preset.id.rawValue), "name": .string(presetRenameText)]
                )
                model.renamePreset(preset.id, to: presetRenameText)
            } label: {
                Text("Rename", comment: "Rename dialog confirm button, for a shot or a preset")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    "presetRenameCancel.button",
                    domain: .composition,
                    params: ["preset": .string(preset.id.rawValue)]
                )
            } label: {
                Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
            }
        }
    }

    /// Whether the preset rename dialog is up — presented while a preset is
    /// being renamed, and clearing that preset when the dialog dismisses.
    private var isPresetRenamePresented: Binding<Bool> {
        Binding {
            presetBeingRenamed != nil
        } set: { presented in
            if !presented { presetBeingRenamed = nil }
        }
    }

    /// One preset button's context menu: duplicate, rename, reorder (Move Left
    /// / Move Right), and remove that preset — the shot commands, one level up
    /// (ARCHITECTURE.md, "Multiple presets in the UI", "Shot and preset
    /// reordering"). Reorder is meaningful here too: the app adopts the first
    /// preset at launch, so moving one to the front makes it the next session's
    /// default. Remove is immediate like a shot's, but disabled on the last
    /// remaining preset: a project always holds at least one.
    @ViewBuilder private func presetCommands(for preset: Preset) -> some View {
        let index = model.presets.firstIndex { $0.id == preset.id }

        Button {
            model.eventBus.tap(
                "presetDuplicate.menu",
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
            )
            model.duplicatePreset(preset.id)
        } label: {
            Text("Duplicate", comment: "Context menu: duplicate this shot or preset")
        }

        Button {
            model.eventBus.tap(
                "presetRename.menu",
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
            )
            presetRenameText = preset.name
            presetBeingRenamed = preset
        } label: {
            Text("Rename…", comment: "Context menu: rename this shot or preset")
        }

        Divider()

        Button {
            guard let index else { return }
            model.eventBus.tap(
                "presetMoveLeft.menu",
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "index": .int(index)]
            )
            model.movePreset(preset.id, to: index - 1)
        } label: {
            Text("Move Left", comment: "Context menu: move this shot or preset earlier in the switcher order")
        }
        .disabled((index ?? 0) <= 0)

        Button {
            guard let index else { return }
            model.eventBus.tap(
                "presetMoveRight.menu",
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "index": .int(index)]
            )
            model.movePreset(preset.id, to: index + 1)
        } label: {
            Text("Move Right", comment: "Context menu: move this shot or preset later in the switcher order")
        }
        .disabled(index.map { $0 >= model.presets.count - 1 } ?? true)

        Divider()

        Button(role: .destructive) {
            model.eventBus.tap(
                "presetRemove.menu",
                domain: .composition,
                params: ["preset": .string(preset.id.rawValue), "name": .string(preset.name)]
            )
            Task { await model.removePreset(preset.id) }
        } label: {
            Text("Remove Preset", comment: "Preset context menu: remove this preset from the project")
        }
        .disabled(model.presets.count == 1)
    }

    /// The shot switcher: one button per available shot, taking it to program
    /// on tap with the transition the segmented picker selects
    /// (``EngineModel/takeTransitionKind`` — Default resolves the taken
    /// shot's own default transition; Cut, Dissolve, and Wipe override it; a
    /// wipe's edge comes from the adjacent pop-up, shown only while Wipe is
    /// selected). The button for the shot currently on program is
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
                HStack(spacing: 12) {
                    Picker(selection: $model.takeTransitionKind) {
                        Text(
                            "Default",
                            comment: "Transition picker option: take each shot with its own default transition"
                        )
                        .tag(TakeTransitionKind.default)
                        Text("Cut", comment: "Transition picker option: switch to the next shot taken instantly")
                            .tag(TakeTransitionKind.cut)
                        Text("Dissolve", comment: "Transition picker option: crossfade to the next shot taken")
                            .tag(TakeTransitionKind.dissolve)
                        Text(
                            "Wipe",
                            comment:
                                "Transition picker option: reveal the next shot taken across the frame from an edge"
                        )
                        .tag(TakeTransitionKind.wipe)
                    } label: {
                        Text(
                            "Transition",
                            comment: "Label of the picker choosing the transition kind for the next shot take")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: model.takeTransitionKind) { _, newValue in
                        model.eventBus.tap(
                            "transition.picker",
                            domain: .composition,
                            params: ["kind": .string(newValue.rawValue)]
                        )
                    }

                    if model.takeTransitionKind == .wipe {
                        Picker(selection: $model.wipeEdge) {
                            Text("Left", comment: "Wipe edge picker option: reveal from the left edge of the frame")
                                .tag(WipeEdge.left)
                            Text("Right", comment: "Wipe edge picker option: reveal from the right edge of the frame")
                                .tag(WipeEdge.right)
                            Text("Top", comment: "Wipe edge picker option: reveal from the top edge of the frame")
                                .tag(WipeEdge.top)
                            Text("Bottom", comment: "Wipe edge picker option: reveal from the bottom edge of the frame")
                                .tag(WipeEdge.bottom)
                        } label: {
                            Text(
                                "Edge",
                                comment: "Label of the picker choosing the frame edge a wipe reveals the next shot from"
                            )
                        }
                        .fixedSize()
                        .onChange(of: model.wipeEdge) { _, newValue in
                            model.eventBus.tap(
                                "wipeEdge.picker",
                                domain: .composition,
                                params: ["edge": .string(newValue.rawValue)]
                            )
                        }
                    }
                }
            }
        }
        .alert(
            Text("Rename Shot", comment: "Rename shot dialog title"),
            isPresented: isRenamePresented,
            presenting: shotBeingRenamed
        ) { shot in
            TextField(text: $renameText) {
                Text("Name", comment: "Rename dialog text field label, for a shot or a preset")
            }
            Button {
                model.eventBus.tap(
                    "shotRenameConfirm.button",
                    domain: .composition,
                    params: ["shot": .string(shot.id.rawValue), "name": .string(renameText)]
                )
                model.renameShot(shot.id, to: renameText)
            } label: {
                Text("Rename", comment: "Rename dialog confirm button, for a shot or a preset")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    "shotRenameCancel.button",
                    domain: .composition,
                    params: ["shot": .string(shot.id.rawValue)]
                )
            } label: {
                Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
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

    /// One shot button's context menu: duplicate, rename, set the shot's
    /// default transition, reorder (Move Left / Move Right), and remove that
    /// shot (ARCHITECTURE.md, "Shot management", "Shot and preset
    /// reordering", "Per-shot default transitions"). Reorder rides the
    /// context menu — not drag-and-drop — so the shot buttons' single click
    /// stays reserved for the on-air take; the commands mirror the layer
    /// editor's Move Up / Move Down one level up, on the horizontal switcher
    /// axis, and disable at the ends. Remove is immediate — a
    /// destructive-role item, no confirmation: shots are quick to create,
    /// switch, and discard (GLOSSARY.md, "Shot").
    @ViewBuilder private func shotCommands(for shot: Shot) -> some View {
        let index = model.shots.firstIndex { $0.id == shot.id }

        Button {
            model.eventBus.tap(
                "shotDuplicate.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
            )
            model.duplicateShot(shot.id)
        } label: {
            Text("Duplicate", comment: "Context menu: duplicate this shot or preset")
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
            Text("Rename…", comment: "Context menu: rename this shot or preset")
        }

        Menu {
            defaultTransitionPicker(for: shot)
        } label: {
            Text("Default Transition", comment: "Shot context menu: submenu setting this shot's default transition")
        }

        Divider()

        Button {
            guard let index else { return }
            model.eventBus.tap(
                "shotMoveLeft.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "index": .int(index)]
            )
            model.moveShot(shot.id, to: index - 1)
        } label: {
            Text("Move Left", comment: "Context menu: move this shot or preset earlier in the switcher order")
        }
        .disabled((index ?? 0) <= 0)

        Button {
            guard let index else { return }
            model.eventBus.tap(
                "shotMoveRight.menu",
                domain: .composition,
                params: ["shot": .string(shot.id.rawValue), "index": .int(index)]
            )
            model.moveShot(shot.id, to: index + 1)
        } label: {
            Text("Move Right", comment: "Context menu: move this shot or preset later in the switcher order")
        }
        .disabled(index.map { $0 >= model.shots.count - 1 } ?? true)

        Divider()

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

    /// The Default Transition submenu's picker: a checkmarked radio group
    /// choosing the shot's ``Shot/defaultTransition`` — None (an unresolved
    /// take is a cut), Cut, Dissolve, or a wipe from each frame edge, all at
    /// the default durations, matching what the switcher's own picker offers
    /// (ARCHITECTURE.md, "Per-shot default transitions"). The selection
    /// binding reports its `tap` event in its setter — the menu item is where
    /// this user action executes (EVENTS.md, "The `tap` convention") — then
    /// hands the edit to the model, which autosaves it like any other
    /// document edit.
    private func defaultTransitionPicker(for shot: Shot) -> some View {
        let selection = Binding<DefaultTransitionChoice> {
            DefaultTransitionChoice(shot.defaultTransition)
        } set: { choice in
            var params: [String: EventValue] = [
                "shot": .string(shot.id.rawValue),
                "transition": .string(choice.tapValue),
            ]
            if case .wipe(let edge) = choice { params["edge"] = .string(edge.rawValue) }
            model.eventBus.tap("shotDefaultTransition.menu", domain: .composition, params: params)
            model.setShotDefaultTransition(choice.transition, for: shot.id)
        }
        return Picker(selection: selection) {
            Text("No Default", comment: "Default transition option: this shot has no default, so it is taken as set")
                .tag(DefaultTransitionChoice.none)
            Text("Cut", comment: "Transition picker option: switch to the next shot taken instantly")
                .tag(DefaultTransitionChoice.cut)
            Text("Dissolve", comment: "Transition picker option: crossfade to the next shot taken")
                .tag(DefaultTransitionChoice.dissolve)
            Text("Wipe from Left", comment: "Default transition option: wipe revealing this shot from the left edge")
                .tag(DefaultTransitionChoice.wipe(.left))
            Text("Wipe from Right", comment: "Default transition option: wipe revealing this shot from the right edge")
                .tag(DefaultTransitionChoice.wipe(.right))
            Text("Wipe from Top", comment: "Default transition option: wipe revealing this shot from the top edge")
                .tag(DefaultTransitionChoice.wipe(.top))
            Text(
                "Wipe from Bottom",
                comment: "Default transition option: wipe revealing this shot from the bottom edge"
            )
            .tag(DefaultTransitionChoice.wipe(.bottom))
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
        .labelsHidden()
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

/// The Default Transition submenu's selectable choices, mapping a shot's
/// stored ``Shot/defaultTransition`` to and from a checkmarkable menu
/// selection. The mapping is by kind and edge only — a stored default with a
/// hand-edited duration still checkmarks its kind, and choosing a kind here
/// stores it at the default duration, matching what the switcher's own
/// transition picker takes with.
private enum DefaultTransitionChoice: Hashable {
    /// No default: an unresolved take of this shot is a cut.
    case none

    /// An instant cut.
    case cut

    /// A crossfade at the default dissolve duration.
    case dissolve

    /// A directional reveal from the given frame edge at the default wipe
    /// duration.
    case wipe(WipeEdge)

    /// The choice a stored default transition checkmarks.
    ///
    /// - Parameter transition: The shot's stored default, or nil for none.
    /// (`Transition` is module-qualified here: at this file's scope the name
    /// would otherwise collide with SwiftUI's `Transition` protocol.)
    init(_ transition: TingraComposition.Transition?) {
        switch transition {
        case Optional.none:
            self = .none
        case .some(.cut):
            self = .cut
        case .some(.dissolve(duration: _)):
            self = .dissolve
        case .some(.wipe(edge: let edge, duration: _)):
            self = .wipe(edge)
        }
    }

    /// The default transition this choice stores on the shot — nil for
    /// ``none``, the concrete transition at its default duration otherwise.
    var transition: TingraComposition.Transition? {
        switch self {
        case .none: nil
        case .cut: .cut
        case .dissolve: .dissolve
        case .wipe(let edge): .wipe(edge: edge)
        }
    }

    /// The choice's stable name for the menu's `tap` event params (the wipe
    /// edge rides in a separate `edge` param).
    var tapValue: String {
        switch self {
        case .none: "none"
        case .cut: "cut"
        case .dissolve: "dissolve"
        case .wipe: "wipe"
        }
    }
}
