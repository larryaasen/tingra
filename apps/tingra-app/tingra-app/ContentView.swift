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
/// — the preview and program monitors side by side across the full width,
/// the **shot bank** beneath them under a **Shots** heading — over a
/// **control section** carrying the transition panel, the layer-tree editor,
/// the input pickers, the mixer, and the streaming panel.
///
/// That is the broadcast switcher's own arrangement (ARCHITECTURE.md, "The
/// main window's two sections"): everything the operator *watches* is above
/// everything the operator *works*, so an eye checking what is about to go to
/// air never has to cross the controls that put it there. The bank's tiles
/// are the same ``MonitorTile`` the monitors and the multiview window draw,
/// over the shared tally tints, so what a tile shows and what its tally
/// reads cannot differ between surfaces.
///
/// Presets are not here at all: the sidebar's Presets section switches among
/// — and manages — the project's presets (``SidebarView``), and a second row
/// of them across the content only repeated what that list already says
/// (removed 2026-09-06; ARCHITECTURE.md, "Multiple presets in the UI").
/// Shots are the bank's (``ShotBankView``): one tile per shot of the active
/// preset, clicked to stage, with the shared context menu, a plus button in
/// the Shots heading that adds one from any camera, display, or video
/// generator, and a drop target for an input dragged from the sidebar; the
/// sidebar's shot rows and the
/// Shots menu (⌘1–⌘9) stage the same shots. The Program and Preview rows of
/// shot buttons this window carried until 2026-09-07 listed exactly what the
/// bank shows and went with it (ARCHITECTURE.md, "The shot bank"). The
/// **transition panel** (``TransitionPanel``) is where
/// what is staged goes to air: Cut, Take with the selected transition — each
/// shot's own default while the picker is on Default, or an explicit cut,
/// dissolve, wipe, or shader as the override (GLOSSARY.md, "Transition")
/// (ARCHITECTURE.md, "The preview bus"); Fade to Black is in the toolbar
/// with Start Streaming and Record (``FadeToBlackButton``). The pickers pick
/// one camera and one display; the
/// editor (``LayerTreeEditorView``) edits the staged shot's layer tree — the
/// program shot's when nothing is staged — live; the mixer panel (``MixerView``) mixes the audio inputs into the
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

    /// The shot the bank's rename dialog is editing, or `nil` while it is
    /// closed. View-local, like the layer editor's selection: which shot is
    /// being renamed is transient session state.
    @State private var shotBeingRenamed: Shot?

    /// The rename dialog's working text, prefilled with the shot's current
    /// name when the dialog opens.
    @State private var renameText = ""

    /// Each destination's stream-key field text, by destination id. View-local
    /// and never handed to the model as observable state: the keys flow
    /// straight into ``EngineModel/startStreaming(keys:)`` (which stores them
    /// in secure storage) and are prefilled from there — they never touch the
    /// project document or the event bus (ARCHITECTURE.md, "Streaming the
    /// program"). Held here rather than per row because Start collects every
    /// row's key at once.
    @State private var streamKeys: [ProjectDestinationID: String] = [:]

    /// The padding around the window's column of surfaces. Read by
    /// ``StatusBarView`` too, so the bar's readings line up with the panel
    /// headings above them.
    static let columnPadding: CGFloat = 20

    /// The gap between stacked surfaces — and, in the monitoring section,
    /// between the two monitors and between the monitors, the Shots heading,
    /// and the shot bank.
    private static let sectionSpacing: CGFloat = 12

    /// The shortest the monitors may be, so both stay readable in a window
    /// near the 640-point minimum width.
    private static let minimumMonitorsHeight: CGFloat = 150

    /// The width inside the column's padding.
    ///
    /// - Parameter width: The window's width.
    /// - Returns: The usable content width.
    private static func contentWidth(forWindowWidth width: CGFloat) -> CGFloat {
        width - columnPadding * 2
    }

    /// The monitors' height for a given window width: exactly what two
    /// side-by-side 16:9 monitors need when they split the content width
    /// evenly.
    ///
    /// Derived from the **width** rather than taken as a share of the height
    /// because 16:9 monitors have no use for surplus vertical room — a taller
    /// section only grows the letterbox bars above and below the picture. This
    /// way the monitors grow when the window widens, waste nothing when it
    /// heightens, and the surfaces below scroll into reach either way. The
    /// shot bank beneath them sizes its own tiles from the same width
    /// (``ShotBankView/height(forRowWidth:)``).
    ///
    /// - Parameter width: The window's width.
    /// - Returns: The monitors' height, floored at ``minimumMonitorsHeight``.
    private static func monitorsHeight(forWindowWidth width: CGFloat) -> CGFloat {
        let eachMonitorWidth = (contentWidth(forWindowWidth: width) - sectionSpacing) / 2
        return max(minimumMonitorsHeight, eachMonitorWidth * 9 / 16)
    }

    /// The window body: the monitoring section on top, the controls beneath,
    /// the whole column scrollable.
    ///
    /// **Why it scrolls, and why the top section is measured rather than
    /// flexible.** The column stacks seven surfaces — the monitors and the
    /// bank, the transition panel, the layer editor, the device pickers, the
    /// mixer, and the streaming and recording panels — and a plain `VStack`
    /// resolves a shortfall by
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
    /// ``ShotBankView``'s own scroll view and the monitors'
    /// `maxHeight: .infinity` have nothing to resolve against. So the section
    /// takes a definite height, derived from the window's width, which is also
    /// what makes the monitors grow when the window does rather than merely
    /// stop shrinking.
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Self.sectionSpacing) {
                    topSection(windowWidth: proxy.size.width)

                    TransitionPanel(model: model)

                    LayerTreeEditorView(model: model)

                    controls

                    MixerView(model: model)

                    streamingPanel

                    RecordingPanel(model: model)
                }
                .padding(Self.columnPadding)
            }
        }
        .shotRenameDialog(model: model, surface: .switcher, shot: $shotBeingRenamed, text: $renameText)
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
        // The actions that change what goes out to viewers are the window's
        // primary actions, and the toolbar is where those live: always on
        // screen, never scrolled away with the panels that configure them.
        // Fade to Black leads — the production control, a master stage over
        // the program — then the two outputs. Attached here rather than in
        // the scene so Start Streaming can collect the stream keys typed into
        // the panel's rows (``streamKeys``).
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                FadeToBlackButton(model: model)
                StreamButton(model: model, keys: streamKeys)
                RecordButton(model: model)
            }
        }
    }

    /// The monitoring section: the preview and program monitors side by side
    /// across the full content width, each captioned beneath with the shot it
    /// is showing, then a **Shots** heading over the shot bank.
    ///
    /// The monitors split the width evenly, which makes them the largest
    /// surface in the window at every size — the two pictures an operator
    /// reads most. Under each sits its **shot caption** — the name of the shot
    /// staged on preview, the name of the shot on program — because a picture
    /// alone does not say which shot made it: two shots can look alike on a
    /// monitor and differ in what they reference, and the shot switcher's
    /// highlight is scrolled away while the operator watches. The captions
    /// ride outside the monitors' measured height, in their own row, so they
    /// cost the pictures nothing. Below them, under a heading that names it,
    /// sits the **shot bank** (``ShotBankView``): one tile per shot of the
    /// active preset, so the row reads as what the operator can take rather
    /// than as every input the Mac can see (ARCHITECTURE.md, "The shot
    /// bank").
    ///
    /// Both parts take a definite height from the window's width — the
    /// monitors from ``monitorsHeight(forWindowWidth:)``, the bank from
    /// ``ShotBankView/height(forRowWidth:)`` — so the section is laid out by
    /// arithmetic rather than by negotiation; see the body's note on why a
    /// scroll view leaves no other choice, and ``monitorsHeight`` on why the
    /// height comes from the width.
    ///
    /// - Parameter windowWidth: The window's width, from the body's geometry.
    /// - Returns: The monitoring section.
    private func topSection(windowWidth: CGFloat) -> some View {
        let contentWidth = Self.contentWidth(forWindowWidth: windowWidth)
        return VStack(spacing: Self.sectionSpacing) {
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
            .frame(height: Self.monitorsHeight(forWindowWidth: windowWidth))

            HStack(spacing: Self.sectionSpacing) {
                shotCaption(
                    model.previewShot,
                    placeholder: Text(
                        "No shot staged", comment: "Caption under the preview monitor when nothing is staged")
                )
                shotCaption(
                    model.programShot,
                    placeholder: Text(
                        "No shot on program",
                        comment: "Caption under the program monitor when the program is background-only"
                    )
                )
            }

            HStack(spacing: 6) {
                Text("Shots", comment: "Heading over the shot bank beneath the monitors")
                    .font(.headline)
                addShotMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShotBankView(model: model, height: ShotBankView.height(forRowWidth: contentWidth)) { shot in
                renameText = shot.name
                shotBeingRenamed = shot
            }
        }
    }

    /// The Add Shot menu right after the word Shots in the heading: a
    /// plus-in-a-circle glyph opening ``AddShotMenu`` on the bank surface,
    /// the same items as the Shots menu's and the sidebar's Shots section's
    /// Add Shot submenus. It sits beside the heading rather than
    /// as a tile at the end of the bank — or at the far right of the heading,
    /// where a wide window strands it — so the row holds nothing but shots and
    /// the control is next to the word that names what it adds. Not focusable: it is a menu opened by
    /// click, and a focus ring around a bare glyph reads as a stray border.
    private var addShotMenu: some View {
        AddShotMenu(model: model, surface: .bank) {
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .focusEffectDisabled()
        .help(Text("Add a shot to the active preset", comment: "Tooltip on the Add Shot menu"))
        .accessibilityLabel(Text("Add Shot", comment: "Button adding a new empty shot to the preset"))
    }

    /// One monitor's shot caption: the shot's name, centered under the
    /// monitor it describes, or the given placeholder in secondary color when
    /// that bus carries no shot. The two captions share the monitors' column
    /// split, so each sits under its own picture.
    ///
    /// - Parameters:
    ///   - shot: The shot on that bus, or nil for none.
    ///   - placeholder: What to say when there is none.
    /// - Returns: The caption.
    private func shotCaption(_ shot: Shot?, placeholder: Text) -> some View {
        Group {
            if let shot {
                Text(shot.name)
            } else {
                placeholder
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity)
    }

    /// The localized name of the program bus, its monitor's badge. Kept as a
    /// property so the string carries one comment wherever it is used.
    private var programLabel: Text {
        Text("Program", comment: "Name of the program bus — labels its monitor and its switcher row")
    }

    /// The localized name of the preview bus (see ``programLabel``).
    private var previewLabel: Text {
        Text("Preview", comment: "Name of the preview bus — labels its monitor and its switcher row")
    }

    /// The localized badge shown on the program monitor while the program is
    /// faded to black (see ``MonitorTile/statusBadge``).
    private var fadedToBlackLabel: Text {
        Text("Faded to Black", comment: "Badge on the program monitor while the program is faded to black")
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

    /// The streaming panel: the destination list and the session status. Puts
    /// the program the operator already has on air (ARCHITECTURE.md,
    /// "Streaming the program") — video from the compositor, audio from the
    /// mixer panel's program mix — fanned out to every enabled destination as
    /// one session with one leg each. The destination rows lock while
    /// streaming. The Start/Stop control itself is in the window's toolbar
    /// (``StreamButton``), where it stays on screen while this panel scrolls.
    ///
    /// Each stream key is a `SecureField` bound to view-local state in its own
    /// row, collected only at Start — the keys are stored in the Keychain,
    /// never in the project document, an event, or a log.
    private var streamingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Streaming", comment: "Section heading over the destination list and stream status")
                .font(.headline)

            DestinationListView(model: model, keys: $streamKeys)

            HStack(spacing: 12) {
                Spacer()

                streamStatusLabel
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
