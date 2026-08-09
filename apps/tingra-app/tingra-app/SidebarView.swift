//
//  SidebarView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// The main window's leading sidebar: the project's **presets** and the active
/// one's **shots**, the **generators** that synthesize a picture or a sound,
/// the hardware this Mac can see — cameras, displays, audio input devices,
/// audio output devices — and the **destinations** the program streams to, in
/// nine sections.
///
/// **It is the standard macOS sidebar, and that is what makes it Liquid
/// Glass.** The sidebar is the leading column of the window's
/// `NavigationSplitView`, styled `.sidebar`, so on macOS 26 it picks up the
/// Liquid Glass material automatically from being a standard component
/// compiled against the current SDK. Nothing here applies a glass material by
/// hand, and nothing should: the HIG's rule is that the system draws the
/// sidebar's material, and the app's deployment floor is macOS 15 (CLAUDE.md,
/// "Platform Support"), where `glassEffect` does not exist at all — so a
/// hand-rolled version would be both wrong on 26 and unavailable on 15.
///
/// **Every section collapses, and stays that way.** Each is a `Section` over
/// its own expansion binding, so macOS draws the standard source-list
/// disclosure; which sections are folded away persists in
/// ``SidebarPreferences``, because every source list an operator has used
/// remembers that and one that forgot would read as a bug.
///
/// **The order is the signal path.** Presets hold shots, so they sit above
/// them; a shot is what actually goes to air and is the app's own vocabulary
/// (GLOSSARY.md), so it sits above the inputs it is built from; those run
/// captured picture, synthesized picture, captured sound, synthesized sound,
/// then where sound is monitored; and the destinations the program leaves by
/// are last. Top to bottom, the sidebar reads the way the signal flows.
///
/// **A shot row stages that shot; a camera, display, or generator row stages
/// that input; a preset row switches to that preset.** The staging rows are the
/// preview bus, through the two calls that already own it —
/// ``EngineModel/setPreview(_:)`` for a shot (identical to the switcher's
/// preview row, including its toggle: clicking the staged shot again clears
/// preview) and ``EngineModel/stagePreview(showing:)`` for an input, which
/// stages it **full frame and nothing else**. They all carry the same
/// **tally** the input rows' tiles do, from the shared `Tally` tints, so a
/// lamp cannot mean red here and green there. Nothing reaches program from the
/// sidebar: staging is not taking, and Take remains the one step to air.
///
/// A preset row is the odd one and is marked differently on purpose: switching
/// preset is not staging, so ``EngineModel/switchPreset(to:)`` is what it
/// calls, and the active preset wears a **checkmark** rather than a lamp —
/// red means on program everywhere else in this app, and a preset is not on a
/// bus. Preset *management* — duplicate, rename, reorder, remove — stays on
/// the switcher's own context menu, one surface for those decisions.
///
/// The audio sections and the destination section stay inert, which is the
/// same rule rather than an inconsistency: staging has no meaning for a
/// microphone, a tone, an output device, or a destination — a preview bus
/// carries picture — and whether an audio input is in the mix, which output
/// the operator monitors through, and which destinations are streamed to all
/// have controls that own those decisions: the mixer's channel strips, the
/// master strip's monitor picker, and the streaming panel. The one thing an
/// inert row does offer is **Delete**, on the destinations, behind the same
/// confirmation the shot rows raise.
///
/// **The lists are live and event-driven, with no work of their own.** Each
/// device section reads a model list the engine already keeps current from the
/// event bus — `device.connected`/`device.disconnected` for the capture
/// devices (``EngineModel/readDeviceLists()``) and the monitor's Core Audio
/// device stream for the outputs — so a device that comes or goes reaches the
/// sidebar as an event rather than a poll (CLAUDE.md). Listing a device also
/// starts nothing: unlike ``InputRowsView``, whose live tiles are a deliberate
/// and priced exception, a name in a list needs no frames, so nothing here
/// lights a camera indicator or opens a microphone.
struct SidebarView: View {
    /// The engine model. Read for every list; written only through the two
    /// preview calls a row's action makes, and the one delete its shot context
    /// menu confirms.
    let model: EngineModel

    /// The shot row whose Delete is awaiting confirmation, or nil while no
    /// confirmation is up. View-local, like the rename dialogs' subjects in
    /// `ContentView`: which row a dialog is asking about is transient session
    /// state and never reaches the model.
    ///
    /// The **row** rather than the `ShotID` so the confirmation can name the
    /// shot without looking it up again — and so a shot removed by another
    /// surface while the dialog is up simply resolves to nothing when
    /// ``EngineModel/removeShot(_:)`` cannot find the id.
    @State private var shotPendingDeletion: SidebarRow?

    /// The destination row whose Delete is awaiting confirmation, or nil while
    /// no confirmation is up — the shot subject's twin, one section down.
    ///
    /// A second property rather than one shared subject told apart by a flag:
    /// the two confirmations ask different questions (a destination's stream
    /// key goes with it; a shot's does not exist), so they are two alerts, and
    /// an alert presents from its own subject.
    @State private var destinationPendingDeletion: SidebarRow?

    /// The sections currently open, seeded from ``SidebarPreferences`` at
    /// launch and written back as the operator opens and closes them.
    ///
    /// Held in `@State` as well as in preferences rather than read straight
    /// from `UserDefaults` through a binding: a binding whose setter only
    /// wrote to the defaults database would publish nothing, so the section
    /// would not redraw around the click that collapsed it.
    @State private var expandedSections: Set<SidebarSection>

    /// Where the open/closed state persists across launches.
    private let preferences: SidebarPreferences

    /// Creates the sidebar.
    ///
    /// - Parameters:
    ///   - model: The engine model whose shots, devices, and buses it lists.
    ///   - preferences: Where section expansion persists (the standard defaults
    ///     database by default; a throwaway suite under test).
    init(model: EngineModel, preferences: SidebarPreferences = SidebarPreferences()) {
        self.model = model
        self.preferences = preferences
        _expandedSections = State(initialValue: preferences.expandedSections())
    }

    /// The narrowest the sidebar may be dragged: enough for a section header
    /// and a typical shot or device name beside its symbol.
    private static let minimumWidth: CGFloat = 190

    /// The width the sidebar opens at.
    private static let idealWidth: CGFloat = 230

    /// The widest the sidebar may be dragged. Capped because it is a reference
    /// and staging list rather than a working surface — every point it takes
    /// comes off the monitors, which are what the operator actually watches.
    private static let maximumWidth: CGFloat = 340

    /// The nine sections, in signal order: the presets, then the active one's
    /// shots, then the two kinds of picture — captured, then synthesized —
    /// then the two kinds of sound in the same order, then where sound is
    /// heard, then where the program goes.
    var body: some View {
        List {
            presetSection

            shotSection

            cameraSection

            displaySection

            generatorSection

            section(
                .audioInputs,
                header: Text("Audio Inputs", comment: "Sidebar section heading over the audio input device list"),
                rows: SidebarRow.rows(from: model.audioInputs, ofKind: .microphone),
                symbol: "mic",
                emptyLabel: Text(
                    "No audio inputs connected",
                    comment: "Device rail placeholder when no audio input device is discovered"
                )
            )

            section(
                .audioGenerators,
                header: Text("Audio Generators", comment: "Sidebar section heading over the audio generators"),
                rows: SidebarRow.rows(from: model.audioInputs, ofKind: .generator),
                symbol: "waveform",
                emptyLabel: Text(
                    "No audio generators available",
                    comment: "Sidebar placeholder when no audio generator is registered"
                )
            )

            section(
                .audioOutputs,
                header: Text("Audio Outputs", comment: "Sidebar section heading over the audio output device list"),
                rows: SidebarRow.rows(from: model.monitorDevices),
                symbol: "speaker.wave.2",
                emptyLabel: Text(
                    "No audio outputs connected",
                    comment: "Device rail placeholder when no audio output device is discovered"
                )
            )

            destinationSection
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: Self.minimumWidth,
            ideal: Self.idealWidth,
            max: Self.maximumWidth
        )
        .accessibilityLabel(Text("Shots and Devices", comment: "Accessibility label of the main window's sidebar"))
        .alert(
            Text("Delete this shot?", comment: "Confirmation alert title before deleting a shot from the sidebar"),
            isPresented: isDeleteConfirmationPresented,
            presenting: shotPendingDeletion
        ) { row in
            Button(role: .destructive) {
                model.eventBus.tap(
                    "sidebarShotDeleteConfirm.button",
                    domain: .composition,
                    params: ["shot": .string(row.id), "name": .string(row.name)]
                )
                Task { await model.removeShot(ShotID(rawValue: row.id)) }
            } label: {
                Text("Delete", comment: "Sidebar shot context menu item, and its confirmation's confirm button")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    "sidebarShotDeleteCancel.button",
                    domain: .composition,
                    params: ["shot": .string(row.id)]
                )
            } label: {
                Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
            }
        } message: { row in
            Text(
                "\(row.name) will be removed from the preset. This cannot be undone.",
                comment: "Confirmation alert message before deleting a shot; the placeholder is the shot's name"
            )
        }
        .alert(
            Text(
                "Delete this destination?",
                comment: "Confirmation alert title before deleting a destination from the sidebar"
            ),
            isPresented: isDestinationDeleteConfirmationPresented,
            presenting: destinationPendingDeletion
        ) { row in
            Button(role: .destructive) {
                // The destination id is a param, never the URL and never the
                // key: a destination's secret is in the Keychain and an event
                // param is not where a secret goes (EVENTS.md).
                model.eventBus.tap(
                    "sidebarDestinationDeleteConfirm.button",
                    domain: .output,
                    params: ["destination": .string(row.id)]
                )
                model.removeDestination(ProjectDestinationID(rawValue: row.id))
            } label: {
                Text("Delete", comment: "Sidebar shot context menu item, and its confirmation's confirm button")
            }
            Button(role: .cancel) {
                model.eventBus.tap(
                    "sidebarDestinationDeleteCancel.button",
                    domain: .output,
                    params: ["destination": .string(row.id)]
                )
            } label: {
                Text("Cancel", comment: "Rename dialog cancel button, for a shot or a preset")
            }
        } message: { row in
            Text(
                "\(row.name) and its stored stream key will be removed. This cannot be undone.",
                comment: """
                    Confirmation alert message before deleting a destination; \
                    the placeholder is the destination's name
                    """
            )
        }
    }

    /// Whether the delete confirmation is up — presented while a shot row is
    /// awaiting confirmation, and clearing that row when the alert dismisses
    /// (so Escape and the Cancel button both leave no pending subject behind).
    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding {
            shotPendingDeletion != nil
        } set: { presented in
            if !presented { shotPendingDeletion = nil }
        }
    }

    /// Whether the destination delete confirmation is up — the shot
    /// confirmation's twin, over its own subject.
    private var isDestinationDeleteConfirmationPresented: Binding<Bool> {
        Binding {
            destinationPendingDeletion != nil
        } set: { presented in
            if !presented { destinationPendingDeletion = nil }
        }
    }

    /// The preset section: one row per preset in the project, switching to it
    /// when clicked, with the active one checked.
    ///
    /// The rows are the staging rows in every respect an operator can see —
    /// same helper, same label, same whole-row target — because a list of
    /// things you click to work in should behave one way. Only the call
    /// differs: ``EngineModel/switchPreset(to:)`` rather than a preview call,
    /// which is why the help tag names switching rather than staging. It is
    /// also the reason the rows carry no context menu: preset management
    /// lives on the switcher's, and a second place to rename or remove a
    /// preset is a second place for the two to disagree.
    ///
    /// Switching **never interrupts what is on program** (GLOSSARY.md,
    /// "Preset"), so this row is safe to click while live — the same promise
    /// the switcher's buttons make, since it is the same call.
    private var presetSection: some View {
        stagingSection(
            .presets,
            header: Text("Presets", comment: "Label leading the preset switcher row"),
            rows: SidebarRow.rows(presets: model.presets, active: model.activePresetID),
            symbol: "square.stack",
            emptyLabel: Text(
                "No presets in this project",
                comment: "Sidebar placeholder when the project has no presets"
            ),
            help: Text("Switch to this preset", comment: "Tooltip on a sidebar preset row")
        ) { row in
            model.eventBus.tap(
                "sidebarPreset.row",
                domain: .composition,
                params: ["preset": .string(row.id), "name": .string(row.name)]
            )
            // Exact: `PresetID` is a raw-string wrapper, so the row's id is
            // the preset's own identifier and nothing is inferred.
            Task { await model.switchPreset(to: PresetID(rawValue: row.id)) }
        }
    }

    /// The shot section: one row per **authored** shot in the active preset,
    /// staging it on preview when clicked and lit with that shot's tally.
    ///
    /// The automatic shots the app creates to stage a clicked input are left
    /// out (``SidebarRow/rows(shots:onProgram:onPreview:)``); they stay in the
    /// switcher, so nothing becomes unreachable by being absent here.
    private var shotSection: some View {
        stagingSection(
            .shots,
            header: Text("Shots", comment: "Sidebar section heading over the active preset's shots"),
            rows: SidebarRow.rows(
                shots: model.shots,
                onProgram: model.activeShotID,
                onPreview: model.previewShotID
            ),
            symbol: "rectangle.stack",
            emptyLabel: Text(
                "No shots in this preset",
                comment: "Sidebar placeholder when the active preset has no shots"
            ),
            onDelete: { row in
                model.eventBus.tap(
                    "sidebarShotDelete.menu",
                    domain: .composition,
                    params: ["shot": .string(row.id), "name": .string(row.name)]
                )
                shotPendingDeletion = row
            }
        ) { row in
            model.eventBus.tap(
                "sidebarShot.row",
                domain: .composition,
                params: ["shot": .string(row.id), "name": .string(row.name)]
            )
            // Exact: `ShotID` is a raw-string wrapper, so the row's id is the
            // shot's own identifier and nothing is inferred.
            model.setPreview(ShotID(rawValue: row.id))
        }
    }

    /// The camera section: one row per discovered camera, staging that camera
    /// full frame on preview when clicked and lit with its tally.
    private var cameraSection: some View {
        stagingSection(
            .cameras,
            header: Text("Cameras", comment: "Device rail section heading over the camera device list"),
            rows: SidebarRow.rows(
                from: model.cameras,
                ofKind: .camera,
                onProgram: model.programInputIDs,
                onPreview: model.previewInputIDs
            ),
            symbol: "video",
            emptyLabel: Text(
                "No cameras connected",
                comment: "Device rail placeholder when no camera is discovered"
            )
        ) { row in
            model.eventBus.tap(
                "sidebarCamera.row",
                domain: .composition,
                params: ["id": .string(row.id), "name": .string(row.name)]
            )
            Task { await model.stagePreview(showing: InputID(rawValue: row.id)) }
        }
    }

    /// The display section: one row per discovered display, staging that
    /// display full frame on preview when clicked and lit with its tally.
    ///
    /// The camera section with one word changed, and deliberately so: a
    /// display is a discovered `kind` exactly as a camera is, it produces
    /// picture the same way, and ``EngineModel/stagePreview(showing:)``
    /// already handles it — so anything the two sections did differently would
    /// be an inconsistency rather than a distinction.
    ///
    /// An empty section is more often an **authorization** answer than a
    /// hardware one: every Mac has a display, so nothing listed here usually
    /// means Screen Recording has not been granted, which is why the caption
    /// says "available" rather than "connected".
    private var displaySection: some View {
        stagingSection(
            .displays,
            header: Text("Displays", comment: "Sidebar section heading over the display list"),
            rows: SidebarRow.rows(
                from: model.displays,
                ofKind: .display,
                onProgram: model.programInputIDs,
                onPreview: model.previewInputIDs
            ),
            symbol: "display",
            emptyLabel: Text(
                "No displays available",
                comment: "Sidebar placeholder when no display is discovered"
            )
        ) { row in
            model.eventBus.tap(
                "sidebarDisplay.row",
                domain: .composition,
                params: ["id": .string(row.id), "name": .string(row.name)]
            )
            Task { await model.stagePreview(showing: InputID(rawValue: row.id)) }
        }
    }

    /// The destination section: one row per destination the program streams
    /// to, inert, each carrying a Delete that confirms first.
    ///
    /// **Inert on purpose.** Editing a destination — its URL, its name, its
    /// stream key, whether it is enabled — is the streaming panel's, and a
    /// second place to make those decisions is a second place for them to
    /// disagree. What the section adds is the answer to "where does this
    /// project stream", visible while the panel is scrolled away.
    ///
    /// **Delete is the exception, and it asks first.** Removing a destination
    /// also clears its stored stream key (``EngineModel/removeDestination(_:)``
    /// — deleting a destination must not leave its secret in the Keychain),
    /// which is exactly the kind of consequence a compact row in a scanned
    /// list should not have on one click. So it takes the shot rows' shape: the
    /// menu item only *requests* the deletion, and the alert's own destructive
    /// button is the sole caller.
    private var destinationSection: some View {
        section(
            .destinations,
            header: Text("Destinations", comment: "Sidebar section heading over the streaming destination list"),
            rows: SidebarRow.rows(destinations: model.destinations),
            symbol: "antenna.radiowaves.left.and.right",
            emptyLabel: Text(
                "No destinations yet. Add one to stream.",
                comment: "Empty state under the streaming panel's destination list"
            ),
            onDelete: { row in
                model.eventBus.tap(
                    "sidebarDestinationDelete.menu",
                    domain: .output,
                    params: ["destination": .string(row.id)]
                )
                destinationPendingDeletion = row
            }
        )
    }

    /// The video generator section: one row per **generator** that produces a
    /// picture — the bars, PLUGE, alignment, and black patterns — staging it
    /// full frame on preview when clicked and lit with its tally
    /// (GLOSSARY.md, "Generator": an input that synthesizes its content rather
    /// than capturing it).
    ///
    /// Drawn from ``EngineModel/videoInputs`` rather than every registered
    /// generator, and that filter is the point: the 440 Hz tone is a generator
    /// too, and a row that staged it would put an audio input on a video layer
    /// that renders nothing. The tone is listed a section below instead,
    /// inert, beside the microphones it mixes with. Filtering the
    /// **media-role** list by `kind` is the input rows' own arrangement, one
    /// surface over.
    ///
    /// The heading says **Video** Generators for the same reason: with both
    /// kinds listed, an unqualified "Generators" would name only half of what
    /// the sidebar shows.
    private var generatorSection: some View {
        stagingSection(
            .generators,
            header: Text("Video Generators", comment: "Sidebar section heading over the video generators"),
            rows: SidebarRow.rows(
                from: model.videoInputs,
                ofKind: .generator,
                onProgram: model.programInputIDs,
                onPreview: model.previewInputIDs
            ),
            symbol: "rectangle.checkered",
            emptyLabel: Text(
                "No video generators available",
                comment: "Sidebar placeholder when no video generator is registered"
            )
        ) { row in
            model.eventBus.tap(
                "sidebarGenerator.row",
                domain: .composition,
                params: ["id": .string(row.id), "name": .string(row.name)]
            )
            Task { await model.stagePreview(showing: InputID(rawValue: row.id)) }
        }
    }

    /// One clickable section: its heading over a clickable, tally-lit row per
    /// subject, or the given caption when the section is empty.
    ///
    /// Shared by the shot, camera, display, generator, and preset sections
    /// because they differ only in what a click calls — the rows themselves
    /// must look and behave identically, which is what "shots are selectable
    /// like a camera input" means, and what keeps a preset row from becoming a
    /// second kind of thing.
    ///
    /// - Parameters:
    ///   - id: Which section this is, for its expansion and its `tap` name.
    ///   - header: The section's heading.
    ///   - rows: The section's rows, already in row order.
    ///   - symbol: The SF Symbol each row is labeled with.
    ///   - emptyLabel: What to show when `rows` is empty.
    ///   - help: The row's tooltip, naming what a click does (staging by
    ///     default, since every section but the presets stages).
    ///   - onDelete: What the row's Delete context-menu item requests,
    ///     including its `tap`, or nil (the default) for a section whose rows
    ///     carry no context menu. A **request**, not the deletion: the item
    ///     only raises the confirmation, and the alert's own button is what
    ///     removes anything.
    ///   - action: What a click on a row performs, including its `tap`.
    /// - Returns: The section.
    private func stagingSection(
        _ id: SidebarSection,
        header: Text,
        rows: [SidebarRow],
        symbol: String,
        emptyLabel: Text,
        help: Text = Text("Stage on preview", comment: "Tooltip on an input tile that stages it on preview"),
        onDelete: ((SidebarRow) -> Void)? = nil,
        action: @escaping (SidebarRow) -> Void
    ) -> some View {
        Section(isExpanded: expansion(of: id)) {
            if rows.isEmpty {
                emptyLabel
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    stagingRow(row, symbol: symbol, help: help, onDelete: onDelete, action: action)
                }
            }
        } header: {
            header
        }
    }

    /// One clickable row: the tally-lit label, with the shot rows' context
    /// menu when the section supplies one.
    ///
    /// The menu is attached in a branch rather than always, with `nil` content
    /// for the camera section: an always-attached `.contextMenu` whose body is
    /// empty still claims the right-click, so a camera row would answer with a
    /// blank menu instead of the nothing it means.
    ///
    /// - Parameters:
    ///   - row: The row to draw.
    ///   - symbol: The SF Symbol for the row's section.
    ///   - help: The row's tooltip, naming what a click does.
    ///   - onDelete: The section's delete request, or nil for no menu.
    ///   - action: What a click performs.
    /// - Returns: The row.
    @ViewBuilder private func stagingRow(
        _ row: SidebarRow,
        symbol: String,
        help: Text,
        onDelete: ((SidebarRow) -> Void)?,
        action: @escaping (SidebarRow) -> Void
    ) -> some View {
        let button = Button {
            action(row)
        } label: {
            label(row, symbol: symbol)
                // The whole row is the target, not just the glyph and the text.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)

        if let onDelete {
            button.contextMenu {
                Button(role: .destructive) {
                    onDelete(row)
                } label: {
                    Text("Delete", comment: "Sidebar shot context menu item, and its confirmation's confirm button")
                }
            }
        } else {
            button
        }
    }

    /// One inert section: its heading over a row per subject, or the given
    /// caption when there is nothing to list.
    ///
    /// An empty section keeps its heading rather than disappearing, so the
    /// sidebar's shape does not change as hardware comes and goes — and so
    /// "nothing is plugged in" reads as an answer rather than as a section the
    /// operator has to notice is missing.
    ///
    /// - Parameters:
    ///   - id: Which section this is, for its expansion and its `tap` name.
    ///   - header: The section's heading.
    ///   - rows: The section's subjects, already in row order.
    ///   - symbol: The SF Symbol each row is labeled with.
    ///   - emptyLabel: What to show when `rows` is empty.
    ///   - onDelete: What the row's Delete context-menu item requests,
    ///     including its `tap`, or nil (the default) for rows that carry no
    ///     menu — which is every inert section but the destinations. A
    ///     **request**, not the deletion, exactly as in the staging sections.
    /// - Returns: The section.
    private func section(
        _ id: SidebarSection,
        header: Text,
        rows: [SidebarRow],
        symbol: String,
        emptyLabel: Text,
        onDelete: ((SidebarRow) -> Void)? = nil
    ) -> some View {
        Section(isExpanded: expansion(of: id)) {
            if rows.isEmpty {
                emptyLabel
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    inertRow(row, symbol: symbol, onDelete: onDelete)
                }
            }
        } header: {
            header
        }
    }

    /// One inert row: the label, with a Delete context menu when the section
    /// supplies one.
    ///
    /// Branched rather than always-attached for the reason ``stagingRow(_:symbol:help:onDelete:action:)``
    /// records: an empty `.contextMenu` still claims the right-click, so a
    /// microphone row would answer with a blank menu instead of the nothing it
    /// means.
    ///
    /// - Parameters:
    ///   - row: The row to draw.
    ///   - symbol: The SF Symbol for the row's section.
    ///   - onDelete: The section's delete request, or nil for no menu.
    /// - Returns: The row.
    @ViewBuilder private func inertRow(
        _ row: SidebarRow,
        symbol: String,
        onDelete: ((SidebarRow) -> Void)?
    ) -> some View {
        if let onDelete {
            label(row, symbol: symbol)
                // The whole row answers the right-click, not just the glyph
                // and the text — the staging rows' rule, which they get from
                // being buttons.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .contextMenu {
                    Button(role: .destructive) {
                        onDelete(row)
                    } label: {
                        Text(
                            "Delete",
                            comment: "Sidebar shot context menu item, and its confirmation's confirm button"
                        )
                    }
                }
        } else {
            label(row, symbol: symbol)
        }
    }

    /// A binding to whether one section is open, reporting the disclosure's
    /// own `tap` and persisting the new state as it changes.
    ///
    /// The `tap` rides the **binding setter** rather than an `onChange`, the
    /// rule `Binding.reportingTap` was extracted for: a setter runs only when
    /// the operator works the control, so restoring the persisted state at
    /// launch records no tap nobody made (EVENTS.md, "Where a picker's tap is
    /// reported").
    ///
    /// - Parameter section: The section to bind.
    /// - Returns: The binding.
    private func expansion(of section: SidebarSection) -> Binding<Bool> {
        Binding {
            expandedSections.contains(section)
        } set: { isExpanded in
            model.eventBus.tap(
                section.tapName,
                domain: .composition,
                params: ["expanded": .bool(isExpanded)]
            )
            if isExpanded {
                expandedSections.insert(section)
            } else {
                expandedSections.remove(section)
            }
            preferences.setExpanded(isExpanded, for: section)
        }
    }

    /// One row's label: the tally-lit symbol beside the name, with a trailing
    /// checkmark on the row that is its section's current one.
    ///
    /// The symbol takes ``MultiviewTile/Tally/borderTint`` rather than
    /// `badgeTint`, because a row's symbol reads as a **lamp** and the tally
    /// record is explicit that an unlit lamp is no colour at all, not a grey
    /// one — so an idle row draws in the sidebar's ordinary secondary glyph
    /// colour, and only a shot or input actually on a bus is tinted. Red and
    /// green themselves come straight from the shared tints.
    ///
    /// The checkmark is a **separate** mark rather than a third tally colour,
    /// for the reason ``SidebarRow/isCurrent`` records: the active preset is
    /// not on air, and a lamp is the app's word for on air.
    ///
    /// - Parameters:
    ///   - row: The row to label.
    ///   - symbol: The SF Symbol for the row's section.
    /// - Returns: The label.
    private func label(_ row: SidebarRow, symbol: String) -> some View {
        HStack(spacing: 4) {
            Label {
                // A shot's or preset's name is authored and a device's is
                // reported by discovery; both are runtime data, drawn
                // verbatim. A long one truncates in a column this narrow, so
                // the full text stays reachable as a help tag.
                Text(verbatim: row.name)
                    .lineLimit(1)
                    .help(Text(verbatim: row.name))
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(row.tally?.borderTint ?? .secondary)
            }

            if row.isCurrent {
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(
                        Text("Active", comment: "Accessibility label of the checkmark marking the active preset")
                    )
            }
        }
    }
}
