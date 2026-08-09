//
//  ContentView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// The main window, in two sections: a **monitoring section** across the top
/// — the input grid on the left, the preview and program monitors on the
/// right — over a **control section** carrying the preset switcher, the shot
/// switcher, the layer-tree editor, the input pickers, the mixer, and the
/// streaming panel.
///
/// That is the broadcast switcher's own arrangement (ARCHITECTURE.md, "The
/// main window's two sections"): everything the operator *watches* is above
/// everything the operator *works*, so an eye checking what is about to go to
/// air never has to cross the controls that put it there. The input grid is
/// the same ``InputGridView`` the multiview window tiles, so what a tile shows
/// and what its tally reads cannot differ between the two surfaces.
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
/// (ARCHITECTURE.md, "Shot management", "Shot and preset reordering"). A
/// second row of the same shots stages one on **preview** — the staging bus,
/// monitored beside program — and the Take button promotes it, swapping the
/// buses (ARCHITECTURE.md, "The preview bus"); the
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

    /// Each destination's stream-key field text, by destination id. View-local
    /// and never handed to the model as observable state: the keys flow
    /// straight into ``EngineModel/startStreaming(keys:)`` (which stores them
    /// in secure storage) and are prefilled from there — they never touch the
    /// project document or the event bus (ARCHITECTURE.md, "Streaming the
    /// program"). Held here rather than per row because Start collects every
    /// row's key at once.
    @State private var streamKeys: [ProjectDestinationID: String] = [:]

    /// The padding around the window's column of surfaces.
    private static let columnPadding: CGFloat = 20

    /// The gap between stacked surfaces — and, in the monitoring section,
    /// between the input grid and the monitors and between the two monitors.
    private static let sectionSpacing: CGFloat = 12

    /// The share of the window's content width the input rows take, leaving
    /// the rest to the two monitors.
    ///
    /// A fixed share rather than a layout priority or an `HSplitView`, because
    /// both of those levers do the opposite of what they sound like here: a
    /// priority hands one group everything except the *minimum* of the others,
    /// so it can pin a pane at its narrowest forever, and an `HSplitView` opens
    /// with its first pane collapsed to that pane's minimum and needs a stored
    /// divider position to do better — one more piece of window state to
    /// persist, for a section an operator reads rather than adjusts. A share
    /// keeps both panes growing together, and leaves the monitors the larger
    /// surface at every window size, which is what the multiview window (⌥⌘M)
    /// is for when the wall-of-tiles reading is the one wanted.
    private static let inputRowsWidthFraction: CGFloat = 0.42

    /// The shortest the monitoring section may be, so both monitors stay
    /// readable in a window near the 640-point minimum width.
    private static let minimumTopSectionHeight: CGFloat = 150

    /// The width inside the column's padding.
    ///
    /// - Parameter width: The window's width.
    /// - Returns: The usable content width.
    private static func contentWidth(forWindowWidth width: CGFloat) -> CGFloat {
        width - columnPadding * 2
    }

    /// The width the input rows take at a given window width.
    ///
    /// - Parameter width: The window's width.
    /// - Returns: The input rows' width.
    private static func inputRowsWidth(forWindowWidth width: CGFloat) -> CGFloat {
        contentWidth(forWindowWidth: width) * inputRowsWidthFraction
    }

    /// The monitoring section's height for a given window width: exactly what
    /// two side-by-side 16:9 monitors need at that width.
    ///
    /// Derived from the **width** rather than taken as a share of the height
    /// because 16:9 monitors have no use for surplus vertical room — a taller
    /// section only grows the letterbox bars above and below the picture. This
    /// way the monitors grow when the window widens, waste nothing when it
    /// heightens, and the surfaces below scroll into reach either way. The
    /// input rows beside them take the same height, splitting it in two.
    ///
    /// - Parameter width: The window's width.
    /// - Returns: The section height, floored at ``minimumTopSectionHeight``.
    private static func topSectionHeight(forWindowWidth width: CGFloat) -> CGFloat {
        // The rows' share and the gap beside them come off the top; the
        // remaining room splits between the two monitors.
        let monitorsWidth =
            contentWidth(forWindowWidth: width) - inputRowsWidth(forWindowWidth: width) - sectionSpacing
        let eachMonitorWidth = (monitorsWidth - sectionSpacing) / 2
        return max(minimumTopSectionHeight, eachMonitorWidth * 9 / 16)
    }

    /// The window body: the monitoring section on top, the controls beneath,
    /// the whole column scrollable.
    ///
    /// **Why it scrolls, and why the top section is measured rather than
    /// flexible.** The column stacks seven surfaces — the monitors, both
    /// switcher rows, the layer editor, the device pickers, the mixer, and the
    /// streaming panel — and a plain `VStack` resolves a shortfall by
    /// compressing whatever yields first. That is always the monitors, because
    /// they are the only surface with no intrinsic height to defend. At
    /// ordinary window sizes they collapsed to a sliver *and* pushed the camera
    /// and display pickers below the bottom edge, so the operator could neither
    /// read the program nor choose what fed it — the two things this window
    /// exists to do.
    ///
    /// A `ScrollView` gives the column its natural height and lets the window
    /// show a portion of it. That in turn makes the top section's height a
    /// decision rather than a leftover, which it has to be: a scroll view
    /// proposes an **unbounded** height, and under that proposal
    /// ``InputRowsView``'s own scroll views and the monitors'
    /// `maxHeight: .infinity` have nothing to resolve against. So the section
    /// takes a definite height, derived from the window's width, which is also
    /// what makes the monitors grow when the window does rather than merely
    /// stop shrinking.
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Self.sectionSpacing) {
                    topSection(windowWidth: proxy.size.width)

                    presetSwitcher

                    shotSwitcher

                    LayerTreeEditorView(model: model)

                    controls

                    MixerView(model: model)

                    streamingPanel

                    RecordingPanel(model: model)
                }
                .padding(Self.columnPadding)
            }
        }
        // Only the *effect* of a selection change lives here — it must run
        // however the value changed, including when the model assigns the
        // default at boot. The `tap` rides the pickers' own bindings instead
        // (``cameraSelection``), because only the control can say the
        // operator acted.
        .onChange(of: model.selectedCameraID) { _, _ in
            Task { await model.reconfigure() }
        }
        .onChange(of: model.selectedDisplayID) { _, _ in
            Task { await model.reconfigure() }
        }
    }

    /// The monitoring section: the input rows on the left, the preview and
    /// program monitors on the right.
    ///
    /// The left pane is two rows — every available camera above, the
    /// generators and displays below (``InputRowsView``) — rather than one
    /// adaptive grid. Splitting cameras onto their own line is what makes the
    /// pane scannable: cameras are what an operator reaches for and the row
    /// that changes as hardware comes and goes, so mixing them in among the
    /// patterns costs a search every time.
    ///
    /// Both panes take their width from ``inputRowsWidthFraction`` and their
    /// height from ``topSectionHeight(forWindowWidth:)``, so the section is
    /// laid out by arithmetic rather than by negotiation — see those two for
    /// why a fixed share beats a layout priority or an `HSplitView` here, and
    /// why the height comes from the width.
    ///
    /// - Parameter windowWidth: The window's width, from the body's geometry.
    /// - Returns: The monitoring section.
    private func topSection(windowWidth: CGFloat) -> some View {
        let height = Self.topSectionHeight(forWindowWidth: windowWidth)
        return HStack(spacing: Self.sectionSpacing) {
            InputRowsView(model: model, height: height)
                .frame(width: Self.inputRowsWidth(forWindowWidth: windowWidth))

            HStack(spacing: Self.sectionSpacing) {
                // Preview left of program, the switcher convention: the
                // operator reads left to right, staging then taking.
                MonitorTile(source: model.previewRelay, label: previewLabel, badgeTint: .green)
                MonitorTile(
                    source: model.programRelay,
                    label: programLabel,
                    badgeTint: .red,
                    statusBadge: model.isFadedToBlack ? fadedToBlackLabel : nil
                )
            }
        }
        .frame(height: height)
    }

    /// The localized name of the program bus, shared by its monitor's badge
    /// and its switcher row's label. Held in one place so both call sites
    /// carry the identical comment, which is what keeps string extraction
    /// from splitting one key in two.
    private var programLabel: Text {
        Text("Program", comment: "Name of the program bus — labels its monitor and its switcher row")
    }

    /// The localized name of the preview bus (see ``programLabel``).
    private var previewLabel: Text {
        Text("Preview", comment: "Name of the preview bus — labels its monitor and its switcher row")
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
                Text("Name", comment: "Name text field label — for a shot, a preset, or a destination")
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
                programLabel
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

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

            previewRow

            if !model.shots.isEmpty {
                HStack(spacing: 12) {
                    Picker(
                        selection: $model.takeTransitionKind.reportingTap(
                            to: model.eventBus, "transition.picker", domain: .composition,
                            params: { ["kind": .string($0.rawValue)] })
                    ) {
                        Text(
                            "Default",
                            comment: "Transition picker option: take each shot with its own default transition"
                        )
                        .tag(TakeTransitionKind.default)
                        Text(
                            "Cut",
                            comment:
                                "Switch to the next shot taken instantly — the transition picker option, and the Cut button"
                        )
                        .tag(TakeTransitionKind.cut)
                        Text("Dissolve", comment: "Transition picker option: crossfade to the next shot taken")
                            .tag(TakeTransitionKind.dissolve)
                        Text(
                            "Wipe",
                            comment:
                                "Transition picker option: reveal the next shot taken across the frame from an edge"
                        )
                        .tag(TakeTransitionKind.wipe)
                        Text(
                            "Shader",
                            comment:
                                "Transition picker option: reveal the next shot taken through a built-in custom shader"
                        )
                        .tag(TakeTransitionKind.shader)
                    } label: {
                        Text(
                            "Transition",
                            comment: "Label of the picker choosing the transition kind for the next shot take")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    if model.takeTransitionKind == .wipe {
                        Picker(
                            selection: $model.wipeEdge.reportingTap(
                                to: model.eventBus, "wipeEdge.picker", domain: .composition,
                                params: { ["edge": .string($0.rawValue)] })
                        ) {
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
                    }

                    if model.takeTransitionKind == .shader {
                        Picker(
                            selection: $model.shaderName.reportingTap(
                                to: model.eventBus, "shaderName.picker", domain: .composition,
                                params: { ["shader": .string($0.rawValue)] })
                        ) {
                            Text("Iris", comment: "Shader picker option: circular reveal opening from the center")
                                .tag(TransitionShader.iris)
                            Text(
                                "Diagonal",
                                comment: "Shader picker option: diagonal sweep from the top-left corner"
                            )
                            .tag(TransitionShader.diagonal)
                            Text("Blinds", comment: "Shader picker option: horizontal bands revealing in parallel")
                                .tag(TransitionShader.blinds)
                        } label: {
                            Text(
                                "Shader",
                                comment:
                                    "Label of the picker choosing the built-in shader a shader transition reveals with"
                            )
                        }
                        .fixedSize()
                    }
                }
            }

            fadeToBlackControl
        }
        .alert(
            Text("Rename Shot", comment: "Rename shot dialog title"),
            isPresented: isRenamePresented,
            presenting: shotBeingRenamed
        ) { shot in
            TextField(text: $renameText) {
                Text("Name", comment: "Name text field label — for a shot, a preset, or a destination")
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

    /// The preview row: the same shots again, one row down, staging rather
    /// than taking (ARCHITECTURE.md, "The preview bus"). A second row rather
    /// than a modifier-click on the program row, because the program row's
    /// single click is the live on-air take — the reasoning that kept
    /// drag-and-drop off those buttons: a mis-modified click must never put
    /// the wrong shot to air. Clicking the staged shot again clears preview,
    /// so the row toggles.
    ///
    /// The trailing Take button promotes what is staged, swapping the buses,
    /// with the transition the picker below selects. It is disabled while
    /// nothing is staged — there is nothing to take.
    @ViewBuilder private var previewRow: some View {
        if !model.shots.isEmpty {
            HStack(spacing: 8) {
                previewLabel
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(model.shots.enumerated()), id: \.element.id) { index, shot in
                    let isStaged = shot.id == model.previewShotID
                    Button(shot.name) {
                        model.eventBus.tap(
                            ProgramLayout.previewTapName(forShotID: shot.id),
                            domain: .composition,
                            params: ["shot": .string(shot.id.rawValue), "name": .string(shot.name)]
                        )
                        model.setPreview(shot.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(isStaged ? .green : nil)
                    // ⌘1…⌘9 by position, the switcher convention every
                    // surveyed app shares (``ProductionShortcut``). A tenth
                    // shot simply has none — the optional overload takes nil.
                    .keyboardShortcut(ProductionShortcut.stageShotShortcut(forIndex: index))
                }

                // Cut left of Take, the order the two live side by side on a
                // hardware panel: CUT takes instantly, AUTO takes over the
                // armed transition.
                Button {
                    model.eventBus.tap(
                        "cut.button",
                        domain: .composition,
                        params: ["shot": .string(model.previewShotID?.rawValue ?? "none")]
                    )
                    model.cutPreview()
                } label: {
                    ProductionShortcut.cut.name
                }
                .buttonStyle(.bordered)
                .disabled(model.previewShotID == nil)
                .keyboardShortcut(ProductionShortcut.cut.shortcut)

                Button {
                    model.eventBus.tap(
                        "take.button",
                        domain: .composition,
                        params: ["shot": .string(model.previewShotID?.rawValue ?? "none")]
                    )
                    model.takePreview()
                } label: {
                    Text("Take", comment: "Button taking the shot staged on preview to program")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.previewShotID == nil)
                .keyboardShortcut(ProductionShortcut.take.shortcut)
            }
        }
    }

    /// The **fade to black** control: one latching button that takes the
    /// whole program off air — picture *and* sound together — and brings it
    /// back (GLOSSARY.md, "Fade to black").
    ///
    /// Its own row beneath the transition controls, because it is a **master
    /// stage rather than a transition**: a transition is the move from one
    /// shot to the next, where this holds across shot switches. It stays
    /// available when the preset has no shots — the operator must always be
    /// able to take the program down — which is why it sits outside the
    /// switcher's shots guard. Prominent and red while active, the broadcast
    /// convention for a latched FTB.
    private var fadeToBlackControl: some View {
        HStack(spacing: 8) {
            Button {
                model.eventBus.tap(
                    "fadeToBlack.button",
                    domain: .composition,
                    params: ["state": .string(model.isFadedToBlack ? "clear" : "black")]
                )
                model.setFadeToBlack(!model.isFadedToBlack)
            } label: {
                fadeToBlackLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isFadedToBlack ? .red : .gray)
            .keyboardShortcut(ProductionShortcut.fadeToBlack.shortcut)

            if model.isFadedToBlack {
                fadedToBlackHint
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The localized name of the fade-to-black control.
    private var fadeToBlackLabel: Text {
        Text("Fade to Black", comment: "Button taking the whole program — picture and sound — off air, and back")
    }

    /// The localized badge shown on the program monitor while the program is
    /// faded to black (see ``MonitorTile/statusBadge``).
    private var fadedToBlackLabel: Text {
        Text("Faded to Black", comment: "Badge on the program monitor while the program is faded to black")
    }

    /// The localized hint beside the control while the program is down,
    /// naming what is still live behind the fade.
    private var fadedToBlackHint: Text {
        Text(
            "Viewers see and hear nothing. Preview and multiview stay live.",
            comment: "Hint beside the fade to black control while the program is off air"
        )
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
    /// take is a cut), Cut, Dissolve, a wipe from each frame edge, or a
    /// built-in shader transition, all at
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
            if case .shader(let name) = choice { params["shader"] = .string(name.rawValue) }
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
            Text("Iris", comment: "Shader picker option: circular reveal opening from the center")
                .tag(DefaultTransitionChoice.shader(.iris))
            Text("Diagonal", comment: "Shader picker option: diagonal sweep from the top-left corner")
                .tag(DefaultTransitionChoice.shader(.diagonal))
            Text("Blinds", comment: "Shader picker option: horizontal bands revealing in parallel")
                .tag(DefaultTransitionChoice.shader(.blinds))
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// The camera picker's selection, reporting the picker's `tap` when the
    /// operator changes it — never when the model assigns the default during
    /// boot (see ``Binding/reportingTap(to:_:domain:params:)``).
    private var cameraSelection: Binding<InputID?> {
        // Snapshotted rather than captured, so the tap names the list the
        // picker was showing when the operator chose from it.
        let cameras = model.cameras
        return $model.selectedCameraID.reportingTap(to: model.eventBus, "camera.picker", domain: .capture) {
            newValue in
            [
                "id": .string(newValue?.rawValue ?? "none"),
                "name": .string(cameras.first { $0.id == newValue }?.name ?? "None"),
            ]
        }
    }

    /// The display picker's selection (see ``cameraSelection``).
    private var displaySelection: Binding<InputID?> {
        let displays = model.displays
        return $model.selectedDisplayID.reportingTap(to: model.eventBus, "display.picker", domain: .capture) {
            newValue in
            [
                "id": .string(newValue?.rawValue ?? "none"),
                "name": .string(displays.first { $0.id == newValue }?.name ?? "None"),
            ]
        }
    }

    /// The selected input's id when the given choices no longer contain it —
    /// what a picker needs its own entry for.
    ///
    /// A device that is unplugged **stays cast** in its role, dormant, so it
    /// resumes when it returns — the same rule as a layer bound to an
    /// undiscovered input and a channel strip whose device is absent. A
    /// SwiftUI selection matching no tag is undefined behaviour, though, so
    /// keeping the selection means the picker has to be able to draw it
    /// (ARCHITECTURE.md, "Live device lists in the app").
    ///
    /// - Parameters:
    ///   - selection: The picker's current selection.
    ///   - choices: The inputs the picker is listing.
    /// - Returns: The unresolvable selection, or nil when it resolves.
    private func dormantSelection(_ selection: InputID?, among choices: [EngineModel.InputChoice]) -> InputID? {
        guard let selection else { return nil }
        return choices.contains { $0.id == selection } ? nil : selection
    }

    /// The camera and display pickers.
    private var controls: some View {
        HStack(spacing: 20) {
            Picker(selection: cameraSelection) {
                Text("None", comment: "Picker option for no input selected").tag(InputID?.none)
                if let dormant = dormantSelection(model.selectedCameraID, among: model.cameras) {
                    Text(
                        "\(model.inputName(for: dormant)) (Not connected)",
                        comment: "Picker entry for a selected device that is not currently connected"
                    )
                    .tag(InputID?.some(dormant))
                }
                ForEach(model.cameras) { camera in
                    Text(camera.name).tag(InputID?.some(camera.id))
                }
            } label: {
                Text("Camera", comment: "Camera input picker label")
            }

            Picker(selection: displaySelection) {
                Text("None", comment: "Picker option for no input selected").tag(InputID?.none)
                if let dormant = dormantSelection(model.selectedDisplayID, among: model.displays) {
                    Text(
                        "\(model.inputName(for: dormant)) (Not connected)",
                        comment: "Picker entry for a selected device that is not currently connected"
                    )
                    .tag(InputID?.some(dormant))
                }
                ForEach(model.displays) { display in
                    Text(display.name).tag(InputID?.some(display.id))
                }
            } label: {
                Text("Display", comment: "Display input picker label")
            }
        }
        .pickerStyle(.menu)
    }

    /// The streaming panel: the destination list, the session status, and the
    /// Start/Stop control. Puts the program the operator already has on air
    /// (ARCHITECTURE.md, "Streaming the program") — video from the
    /// compositor, audio from the mixer panel's program mix — fanned out to
    /// every enabled destination as one session with one leg each. The
    /// destination rows lock while streaming.
    ///
    /// Each stream key is a `SecureField` bound to view-local state in its own
    /// row, collected only at Start — the keys are stored in the Keychain,
    /// never in the project document, an event, or a log.
    private var streamingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Streaming", comment: "Section heading over the destination and Start/Stop controls")
                .font(.headline)

            DestinationListView(model: model, keys: $streamKeys)

            HStack(spacing: 12) {
                Spacer()

                streamStatusLabel

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
                        let keys = streamKeys
                        Task { await model.startStreaming(keys: keys) }
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
                .disabled(!model.isStreaming && !model.hasStreamableDestination)
                // ⌘G — Ecamm Live's own Go Live assignment, and the one
                // shortcut that has to work without the operator hunting for
                // this panel (``ProductionShortcut``). Bound to the control
                // rather than to a menu item so it carries the stream keys
                // typed into the rows above and the same disabled rule.
                .keyboardShortcut(ProductionShortcut.goLive.shortcut)
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

    /// A custom-shader reveal with the given built-in shader at the default
    /// shader-transition duration.
    case shader(TransitionShader)

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
        case .some(.shader(name: let name, duration: _)):
            self = .shader(name)
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
        case .shader(let name): .shader(name: name)
        }
    }

    /// The choice's stable name for the menu's `tap` event params (the wipe
    /// edge and the shader name ride in separate `edge`/`shader` params).
    var tapValue: String {
        switch self {
        case .none: "none"
        case .cut: "cut"
        case .dissolve: "dissolve"
        case .wipe: "wipe"
        case .shader: "shader"
        }
    }
}
