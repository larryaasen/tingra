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

/// The main window's leading sidebar: the active preset's **shots**, the
/// **generators** that synthesize a picture, and the hardware this Mac can see
/// — cameras, audio input devices, audio output devices — in five sections.
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
/// **Shots first, then devices, and the order is the operator's.** A shot is
/// what actually goes to air, and it is the app's own vocabulary
/// (GLOSSARY.md); the devices beneath it are what shots are built from. So the
/// section an operator reaches for most sits where a sidebar's first section
/// sits.
///
/// **A shot row stages that shot; a camera or generator row stages that
/// input.** Both are the preview bus, through the two calls that already own it
/// —
/// ``EngineModel/setPreview(_:)`` for a shot (identical to the switcher's
/// preview row, including its toggle: clicking the staged shot again clears
/// preview) and ``EngineModel/stagePreview(showing:)`` for a camera or a
/// generator, which stages that input **full frame and nothing else**. All
/// three carry the same
/// **tally** the input rows' tiles do, from the shared `Tally` tints, so a
/// lamp cannot mean red here and green there. Nothing reaches program from the
/// sidebar: staging is not taking, and Take remains the one step to air.
///
/// The audio sections stay inert, which is the same rule rather than an
/// inconsistency: staging has no meaning for a microphone or an output device,
/// and whether an audio input is in the mix and which output the operator
/// monitors through already have controls that own those decisions — the
/// mixer's channel strips and the master strip's monitor picker.
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

    /// The five sections: the shots that go to air, then the two kinds of
    /// picture — captured, then synthesized — then what is heard, then where
    /// it is heard.
    var body: some View {
        List {
            shotSection

            cameraSection

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
                .audioOutputs,
                header: Text("Audio Outputs", comment: "Sidebar section heading over the audio output device list"),
                rows: SidebarRow.rows(from: model.monitorDevices),
                symbol: "speaker.wave.2",
                emptyLabel: Text(
                    "No audio outputs connected",
                    comment: "Device rail placeholder when no audio output device is discovered"
                )
            )
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

    /// The generator section: one row per **generator** that produces a
    /// picture — the bars, PLUGE, alignment, and black patterns — staging it
    /// full frame on preview when clicked and lit with its tally
    /// (GLOSSARY.md, "Generator": an input that synthesizes its content rather
    /// than capturing it).
    ///
    /// Drawn from ``EngineModel/videoInputs`` rather than every registered
    /// generator, and that filter is the point: the 440 Hz tone is a generator
    /// too, and a row that staged it would put an audio input on a video layer
    /// that renders nothing. The tone belongs to the mixer, where it already
    /// has a channel strip. Filtering the **media-role** list by `kind` is the
    /// input rows' own arrangement, one surface over.
    private var generatorSection: some View {
        stagingSection(
            .generators,
            header: Text("Generators", comment: "Sidebar section heading over the video generators"),
            rows: SidebarRow.rows(
                from: model.videoInputs,
                ofKind: .generator,
                onProgram: model.programInputIDs,
                onPreview: model.previewInputIDs
            ),
            symbol: "rectangle.checkered",
            emptyLabel: Text(
                "No generators available",
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

    /// One staging section: its heading over a clickable, tally-lit row per
    /// subject, or the given caption when the section is empty.
    ///
    /// Shared by the shot and camera sections because the two differ only in
    /// what a click calls — the rows themselves must look and behave
    /// identically, which is what "shots are selectable like a camera input"
    /// means.
    ///
    /// - Parameters:
    ///   - id: Which section this is, for its expansion and its `tap` name.
    ///   - header: The section's heading.
    ///   - rows: The section's rows, already in row order.
    ///   - symbol: The SF Symbol each row is labeled with.
    ///   - emptyLabel: What to show when `rows` is empty.
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
                    stagingRow(row, symbol: symbol, onDelete: onDelete, action: action)
                }
            }
        } header: {
            header
        }
    }

    /// One staging row: the clickable, tally-lit label, with the shot rows'
    /// context menu when the section supplies one.
    ///
    /// The menu is attached in a branch rather than always, with `nil` content
    /// for the camera section: an always-attached `.contextMenu` whose body is
    /// empty still claims the right-click, so a camera row would answer with a
    /// blank menu instead of the nothing it means.
    ///
    /// - Parameters:
    ///   - row: The row to draw.
    ///   - symbol: The SF Symbol for the row's section.
    ///   - onDelete: The section's delete request, or nil for no menu.
    ///   - action: What a click performs.
    /// - Returns: The row.
    @ViewBuilder private func stagingRow(
        _ row: SidebarRow,
        symbol: String,
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
        .help(Text("Stage on preview", comment: "Tooltip on an input tile that stages it on preview"))

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

    /// One inert section: its heading over a row per device, or the given
    /// caption when nothing of that kind is connected.
    ///
    /// An empty section keeps its heading rather than disappearing, so the
    /// sidebar's shape does not change as hardware comes and goes — and so
    /// "nothing is plugged in" reads as an answer rather than as a section the
    /// operator has to notice is missing.
    ///
    /// - Parameters:
    ///   - id: Which section this is, for its expansion and its `tap` name.
    ///   - header: The section's heading.
    ///   - rows: The section's devices, already in row order.
    ///   - symbol: The SF Symbol each row is labeled with.
    ///   - emptyLabel: What to show when `rows` is empty.
    /// - Returns: The section.
    private func section(
        _ id: SidebarSection,
        header: Text,
        rows: [SidebarRow],
        symbol: String,
        emptyLabel: Text
    ) -> some View {
        Section(isExpanded: expansion(of: id)) {
            if rows.isEmpty {
                emptyLabel
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    label(row, symbol: symbol)
                }
            }
        } header: {
            header
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

    /// One row's label: the tally-lit symbol beside the name.
    ///
    /// The symbol takes ``MultiviewTile/Tally/borderTint`` rather than
    /// `badgeTint`, because a row's symbol reads as a **lamp** and the tally
    /// record is explicit that an unlit lamp is no colour at all, not a grey
    /// one — so an idle row draws in the sidebar's ordinary secondary glyph
    /// colour, and only a shot or camera actually on a bus is tinted. Red and
    /// green themselves come straight from the shared tints.
    ///
    /// - Parameters:
    ///   - row: The row to label.
    ///   - symbol: The SF Symbol for the row's section.
    /// - Returns: The label.
    private func label(_ row: SidebarRow, symbol: String) -> some View {
        Label {
            // A shot's name is authored and a device's is reported by
            // discovery; both are runtime data, drawn verbatim. A long one
            // truncates in a column this narrow, so the full text stays
            // reachable as a help tag.
            Text(verbatim: row.name)
                .lineLimit(1)
                .help(Text(verbatim: row.name))
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(row.tally?.borderTint ?? .secondary)
        }
    }
}
