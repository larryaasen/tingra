//
//  EngineModel.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreVideo
import Observation
import TingraCapturePlugIns
import TingraComposition
import TingraEventBus
import TingraGeneratorPlugIns
import TingraHost
import TingraOutputPlugIns
import TingraPlugInKit

/// The app's engine model: the one `@Observable` that boots the host,
/// activates the first-party plug-ins, and drives the compositor for the
/// on-screen program preview (roadmap step 6).
///
/// It mirrors the CLI's engine wiring (an `InputRegistry`, a `HostClock`, a
/// `PlugInLoader` activating the same plug-ins through the same
/// `PlugInContext`) but ends in the ``Compositor`` and an `MTKView` rather
/// than a streaming service — the app takes shape around the same proven
/// engine, not a fork of it (GLOSSARY.md, "Engine").
///
/// `@MainActor`, per the project's `@Observable` rule: the UI reads its
/// published input lists and selection directly, and every plug-in and
/// compositor call is made from here.
@MainActor
@Observable
final class EngineModel {
    /// One selectable input (a camera or a display) as the pickers show it.
    struct InputChoice: Identifiable, Hashable {
        /// The input's stable identifier.
        let id: InputID

        /// The user-facing name.
        let name: String
    }

    /// The live state of the app's one stream (v1's one-active-session rule),
    /// derived from the `StreamSession` status events on the bus.
    enum StreamStatus: Equatable {
        /// Not streaming.
        case idle

        /// Connecting and starting to publish — after Start, before the
        /// service reports `stream.started`.
        case starting

        /// Live: the program is publishing to the destination.
        case live

        /// The connection dropped and a reconnect attempt is in flight
        /// (`attempt` of `maxAttempts`).
        case reconnecting(attempt: Int, maxAttempts: Int)

        /// The stream stopped cleanly (Stop, or an elapsed duration).
        case stopped

        /// The stream ended on a failure — a start-time rejection (bad key,
        /// unreachable host) or a connection lost past the reconnect budget.
        /// Carries a developer-facing message (never a secret).
        case error(String)
    }

    /// A snapshot of the live stream's delivery counters, from a `stream.stats`
    /// event — what the panel shows beside the Live label.
    struct StreamStats: Equatable {
        /// The current send bitrate in kilobits per second.
        let bitrateKbps: Int

        /// The current delivered frame rate.
        let fps: Int
    }

    /// The discovered cameras, for the camera picker.
    private(set) var cameras: [InputChoice] = []

    /// The discovered displays, for the display picker.
    private(set) var displays: [InputChoice] = []

    /// The chosen camera, or nil for none. The display is the full-frame
    /// background; the camera composites over it as a picture-in-picture.
    var selectedCameraID: InputID?

    /// The chosen display, or nil for none.
    var selectedDisplayID: InputID?

    /// The discovered microphones, for the streaming panel's audio picker.
    private(set) var microphones: [InputChoice] = []

    /// The microphone whose audio is streamed (pass-through on the shared
    /// timeline — the audio mixer is a later iteration), or nil to stream
    /// video only. Session state, not yet part of the project document.
    var selectedMicrophoneID: InputID?

    /// The RTMP(S) destination URL the streaming panel edits, persisted in the
    /// project document (the stream key is not — it lives in secure storage;
    /// see ARCHITECTURE.md, "Streaming the program"). Empty until configured.
    var destinationURL: String = ""

    /// The live streaming status, driven entirely by the `stream.*` events on
    /// the bus (never a poll) — what the Start/Stop control reflects.
    private(set) var streamStatus: StreamStatus = .idle

    /// The latest delivery stats from the last `stream.stats` event while
    /// live, or nil when not streaming — the panel shows them beside the Live
    /// label. Event-driven, like ``streamStatus``.
    private(set) var streamStats: StreamStats?

    /// Whether a stream is currently starting, live, or reconnecting — so the
    /// control shows Stop and the destination fields lock.
    var isStreaming: Bool {
        switch streamStatus {
        case .starting, .live, .reconnecting: return true
        case .idle, .stopped, .error: return false
        }
    }

    /// The shots the current selection makes available, in switcher order —
    /// what the shot switcher lists (roadmap step 7).
    private(set) var shots: [Shot] = []

    /// The id of the shot currently on program, so the switcher can highlight
    /// it. `nil` when there are no shots (no input selected).
    private(set) var activeShotID: ShotID?

    /// The shot currently selected in the switcher — the one the layer-tree
    /// editor edits. `nil` when there are no shots.
    var activeShot: Shot? {
        shots.first { $0.id == activeShotID }
    }

    /// The inputs a new layer can bind to: every discovered camera and
    /// display. Generators stay out until the `Input` seam can declare video
    /// vs audio capability (see ARCHITECTURE.md, "The layer-tree editor").
    var layerInputChoices: [InputChoice] {
        cameras + displays
    }

    /// Whether the next shot switcher tap dissolves rather than cuts
    /// (GLOSSARY.md, "Transition"). A plain toggle bound from `ContentView`;
    /// the switcher itself still always reports the cut/dissolve choice it
    /// used, never guesses at intent.
    var useDissolveTransition = false

    /// The latest program frame, handed to the preview view to draw. Held
    /// in a plain relay (not observed) so the ~30 fps program does not churn
    /// SwiftUI — the `MTKView` samples it at display rate (CLOCK.md).
    @ObservationIgnored let programRelay = ProgramFrameRelay()

    /// The host event bus. In this dev scaffold its events are printed to
    /// stdout (the Xcode console) via ``ConsoleEventSink`` rather than routed
    /// to OSLog, which does not surface in Xcode's debug console.
    ///
    /// Not `private`: every `tap` event is reported by the UI code that
    /// executes the action (a `Button`'s action closure, a picker's
    /// `onChange`), not by the model on the view's behalf — so `ContentView`
    /// calls `model.eventBus.tap(...)` directly (EVENTS.md, "The `tap`
    /// convention").
    @ObservationIgnored let eventBus = EventBus()

    /// The master clock (see CLOCK.md).
    @ObservationIgnored private let clock = HostClock()

    /// The input registry the plug-ins register into.
    @ObservationIgnored private let registry = InputRegistry()

    /// The output registry the streaming plug-in registers into — the same
    /// seam the CLI resolves a destination scheme against
    /// (`OutputRegistry.provider(forScheme:)`).
    @ObservationIgnored private let outputs = OutputRegistry()

    /// The host's Keychain-backed secret store: the stream key lives only
    /// here, keyed by the destination URL — never the project document, never
    /// an event, never a log (CLAUDE.md, "Error Handling").
    @ObservationIgnored private let secureStorage: any SecureStorage = KeychainSecureStorage()

    /// The active stream session, or nil when not streaming (v1's one active
    /// session — GLOSSARY.md, "Session").
    @ObservationIgnored private var streamSession: StreamSession?

    /// The task running the active session's `run()`, retained so its outcome
    /// resolves the status and cleans up.
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    /// The continuation feeding the active session its program video: the one
    /// program drain (``programTask``) tees each composited frame here while a
    /// stream is live, so streaming reuses the same program the preview shows
    /// without opening a second `Compositor.programFrames()` consumer.
    @ObservationIgnored private var streamContinuation: AsyncStream<CapturedFrame>.Continuation?

    /// The task observing the bus for `stream.*` status events — the stream
    /// status is event-driven, never polled.
    @ObservationIgnored private var streamStatusTask: Task<Void, Never>?

    /// The program geometry and rate.
    @ObservationIgnored private let format = ProgramFormat(width: 1920, height: 1080, frameRate: 30)

    /// The id of the session preset — the project's first preset once loaded,
    /// or the stable `"default"` token when this launch seeds a fresh project.
    /// A preset switcher and multiple presets arrive in a later iteration.
    @ObservationIgnored private var presetID = PresetID(rawValue: "default")

    /// The user-facing name of the session preset, carried through saves. Not
    /// yet surfaced in the UI, so the seeded name stays unlocalized for now.
    @ObservationIgnored private var presetName = "Default"

    /// The loaded project's presets after the first, preserved verbatim on
    /// save — the document format holds an array even though the UI surfaces
    /// only the first preset (see ARCHITECTURE.md, "Project save/load").
    @ObservationIgnored private var otherPresets: [Preset] = []

    /// Whether the session preset exists yet — loaded from the project file
    /// in ``start()``, or seeded from ``ProgramLayout`` on the first
    /// configuration pass. Nothing saves before it does.
    @ObservationIgnored private var hasSessionPreset = false

    /// The store the project document loads from and autosaves to.
    @ObservationIgnored private let store = ProjectStore()

    /// The pending debounced autosave, if any — each edit restarts the delay
    /// so a slider drag coalesces into one write (see ``scheduleAutosave()``).
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    /// The camera currently cast in the built-in camera role — the device the
    /// preset's camera-bound layers were last bound to. A camera picker
    /// change rebinds this device's layers to the new choice; picking "None"
    /// parks it (the input stops, the layers keep their binding). Nil when no
    /// camera has ever been cast (its layers are edited manually instead).
    @ObservationIgnored private var boundCameraID: InputID?

    /// The display currently cast in the built-in display role (see
    /// ``boundCameraID``).
    @ObservationIgnored private var boundDisplayID: InputID?

    /// The compositor producing the program frames.
    @ObservationIgnored private lazy var compositor = Compositor(
        clock: clock,
        format: format,
        eventBus: eventBus
    )

    /// The console sink's drain task, retained so the sink keeps consuming
    /// the bus for the app's lifetime.
    @ObservationIgnored private var logSinkTask: Task<Void, Never>?

    /// The inputs currently started, keyed by id, so selection changes start
    /// and stop only what actually changed.
    @ObservationIgnored private var activeInputs: [InputID: any Input] = [:]

    /// The task draining the compositor's program stream into the relay.
    @ObservationIgnored private var programTask: Task<Void, Never>?

    /// Whether ``start()`` has run, so it boots the engine once.
    @ObservationIgnored private var started = false

    /// The display selection the last ``applyConfiguration()`` pass applied,
    /// so a pass can tell a selection change (rebind the built-in role's
    /// layers) from a layer-tree edit (only sync inputs).
    @ObservationIgnored private var appliedDisplayID: InputID?

    /// The camera selection the last ``applyConfiguration()`` pass applied
    /// (see ``appliedDisplayID``).
    @ObservationIgnored private var appliedCameraID: InputID?

    /// Whether any ``applyConfiguration()`` pass has completed, so the first
    /// pass always counts as a selection change and establishes the session
    /// preset even when nothing is selected (a background-only program).
    @ObservationIgnored private var hasAppliedConfiguration = false

    /// Whether a ``reconfigure()`` pass is currently running. `reconfigure()`
    /// suspends at `input.start()`/`stop()`, so without this guard the
    /// startup selection changes (two `onChange` handlers) and the explicit
    /// boot call would interleave and race the input start/stop.
    @ObservationIgnored private var reconfiguring = false

    /// Set whenever a reconfigure is requested while one is already running,
    /// so the running pass loops once more and applies the latest selection —
    /// coalescing a burst of requests into the minimum number of passes.
    @ObservationIgnored private var reconfigureRequested = false

    /// Creates the model. The engine boots in ``start()`` when the window
    /// appears, not here.
    init() {}

    /// Boots the engine: attaches the log sink, activates the capture and
    /// generator plug-ins, discovers inputs, starts the compositor, and
    /// begins feeding the preview. Idempotent.
    func start() async {
        guard !started else { return }
        started = true

        // Print events to the Xcode console (stdout) rather than OSLog, which
        // does not appear in Xcode's debug console (see ``ConsoleEventSink``).
        logSinkTask = eventBus.attach(ConsoleEventSink())
        // Observe the bus for `stream.*` status changes before anything can
        // stream, so no status event is missed (event-driven, never polled).
        let streamEvents = eventBus.events()
        streamStatusTask = Task { [weak self] in
            for await event in streamEvents {
                self?.handleStreamStatusEvent(event)
            }
        }
        let context = PlugInContext(
            eventBus: eventBus,
            clock: clock,
            inputs: registry,
            outputs: outputs,
            tools: UnusedToolRegistering()
        )
        await PlugInLoader().activate(
            [
                AVFoundationCapturePlugIn(), ScreenCaptureKitCapturePlugIn(), GeneratorPlugIn(),
                HaishinKitOutputPlugIn(),
            ],
            in: context
        )

        let inputs = await registry.allInputs
        cameras = inputs.filter { $0.kind == .camera }.map { InputChoice(id: $0.id, name: $0.name) }
        displays = inputs.filter { $0.kind == .display }.map { InputChoice(id: $0.id, name: $0.name) }
        microphones = inputs.filter { $0.kind == .microphone }.map { InputChoice(id: $0.id, name: $0.name) }
        selectedMicrophoneID = microphones.first?.id
        loadProject()

        let program = compositor.programFrames()
        compositor.start()
        programTask = Task { [weak self] in
            var sawFrame = false
            for await frame in program {
                self?.programRelay.latest = frame.pixelBuffer
                // While a stream is live, tee the same program frame into the
                // session — one program drain feeds both the preview and the
                // stream, so the compositor's single-consumer contract holds.
                self?.streamContinuation?.yield(frame)
                if !sawFrame {
                    sawFrame = true
                    // A one-time milestone (not per-frame traffic): confirms the
                    // compositor is producing program frames into the preview
                    // relay at all — the background canvas ticks from the first
                    // frame even before an input delivers.
                    self?.eventBus.event("preview.firstFrame", domain: .composition)
                }
            }
        }

        await reconfigure()
    }

    /// Applies the current camera and display selection to the engine.
    ///
    /// Called from the view whenever a picker changes, and once at boot. It
    /// **coalesces**: only one pass runs at a time (the pass suspends at
    /// `input.start()`/`stop()`), and a request arriving mid-pass makes the
    /// running pass loop once more with the latest selection — so a burst of
    /// requests never overlaps and races the input start/stop.
    func reconfigure() async {
        reconfigureRequested = true
        guard !reconfiguring else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        while reconfigureRequested {
            reconfigureRequested = false
            await applyConfiguration()
        }
    }

    /// One reconfigure pass: rebinds the built-in roles when the
    /// camera/display **selection** changed since the last pass, then starts
    /// newly needed inputs, stops no-longer-needed ones, and hands the active
    /// set to the compositor. A selection change never rebuilds the shots —
    /// layers bound to the previously cast device rebind to the new choice,
    /// so layer-tree edits survive (see ARCHITECTURE.md, "Project
    /// save/load"); on the first pass it instead establishes the session
    /// preset (loading it into the compositor, seeding a fresh project when
    /// no file supplied one).
    ///
    /// An input that cannot start (authorization denied, device gone) is
    /// reported on the bus and left out — the program keeps showing whatever
    /// else is available, never a failure state.
    private func applyConfiguration() async {
        let selectionChanged =
            !hasAppliedConfiguration || selectedDisplayID != appliedDisplayID || selectedCameraID != appliedCameraID

        // A picker change recasts which device plays the built-in role,
        // before the desired-input computation below so the new device starts
        // and the old one stops in this same pass. Picking "None" parks the
        // role's device: no rebind, the layers keep their binding.
        if selectionChanged, hasAppliedConfiguration {
            var edited = false
            if let camera = selectedCameraID, camera != boundCameraID {
                edited = rebindLayers(from: boundCameraID, to: camera) || edited
                boundCameraID = camera
            }
            if let display = selectedDisplayID, display != boundDisplayID {
                edited = rebindLayers(from: boundDisplayID, to: display) || edited
                boundDisplayID = display
            }
            if edited { scheduleAutosave() }
        }

        var desired: [InputID: any Input] = [:]
        if let displayID = selectedDisplayID, let input = await registry.input(withID: displayID) {
            desired[displayID] = input
        }
        if let cameraID = selectedCameraID, let input = await registry.input(withID: cameraID) {
            desired[cameraID] = input
        }
        // Keep every input the session preset's layer trees reference
        // running, except a role's device parked by its picker's "None" — a
        // stopped input's layers keep their binding and simply contribute
        // nothing (the same semantic as a disconnected device).
        var referenced = Set(shots.flatMap { $0.layers.map(\.input) })
        if selectedCameraID == nil, let boundCameraID { referenced.remove(boundCameraID) }
        if selectedDisplayID == nil, let boundDisplayID { referenced.remove(boundDisplayID) }
        for id in referenced where desired[id] == nil {
            if let input = await registry.input(withID: id) {
                desired[id] = input
            }
        }

        for (id, input) in activeInputs where desired[id] == nil {
            await input.stop()
            activeInputs[id] = nil
            eventBus.event("input.stopped", domain: .capture, params: ["id": .string(id.rawValue)])
        }
        for (id, input) in desired where activeInputs[id] == nil {
            do {
                try await input.start()
                activeInputs[id] = input
                eventBus.event(
                    "input.started",
                    domain: .capture,
                    params: ["id": .string(id.rawValue), "name": .string(input.name)]
                )
            } catch {
                eventBus.error(
                    "input.start",
                    domain: .capture,
                    params: [
                        "id": .string(id.rawValue),
                        "error": .string(String(describing: error)),
                    ]
                )
            }
        }

        compositor.setInputs(Array(activeInputs.values))
        eventBus.event(
            "compositor.inputs",
            domain: .composition,
            params: ["ids": .string(activeInputs.keys.map(\.rawValue).sorted().joined(separator: ","))]
        )
        if selectionChanged {
            appliedDisplayID = selectedDisplayID
            appliedCameraID = selectedCameraID
            if !hasAppliedConfiguration {
                hasAppliedConfiguration = true
                establishSessionPreset()
            }
        }
    }

    /// Takes the shot with the given id to program, using ``useDissolveTransition``
    /// to choose a cut or a dissolve (GLOSSARY.md, "Transition"). Driven by
    /// the shot switcher button; the compositor renders it starting the next
    /// tick.
    ///
    /// Reports no `tap` event itself — the switcher button's action closure
    /// in `ContentView` reports the tap before calling this, right where the
    /// user action is executed (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter shotID: The id of the shot to take to program.
    func take(_ shotID: ShotID) {
        compositor.take(shotID: shotID, transition: useDissolveTransition ? .dissolve : .cut)
        activeShotID = shotID
    }

    /// Adds a new, empty user-authored shot (fresh UUID, localized default
    /// name, no layers over black — see ``ShotEdit/newShot()``) at the end of
    /// the switcher order. Adding is not taking: the program is untouched
    /// until the operator takes the new shot (ARCHITECTURE.md, "Shot
    /// management"). The edit autosaves through the project-document path.
    func addShot() {
        guard hasSessionPreset else { return }
        let shot = ShotEdit.newShot()
        shots.append(shot)
        compositor.addShot(shot)
        scheduleAutosave()
    }

    /// Duplicates a shot — the source's layer tree and background under a
    /// fresh UUID and a "<name> copy" name — inserting the copy right after
    /// its source in the switcher order. The duplicate references the same
    /// inputs the source already keeps running, so no reconfigure is needed.
    ///
    /// - Parameter shotID: The id of the shot to duplicate.
    func duplicateShot(_ shotID: ShotID) {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let copy = ShotEdit.duplicate(of: shots[index])
        shots.insert(copy, at: index + 1)
        compositor.addShot(copy, at: index + 1)
        scheduleAutosave()
    }

    /// Renames a shot, preserving its identity and layer tree. A rename to an
    /// empty (or whitespace-only) name is ignored — a switcher button needs a
    /// label (see ``ShotEdit/renaming(_:to:)``). The rename flows through the
    /// compositor's existing `updateShot` path, so the switcher and any
    /// on-program shot reflect it at the next tick.
    ///
    /// - Parameters:
    ///   - shotID: The id of the shot to rename.
    ///   - name: The new user-facing name.
    func renameShot(_ shotID: ShotID, to name: String) {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let renamed = ShotEdit.renaming(shots[index], to: name)
        guard renamed != shots[index] else { return }
        shots[index] = renamed
        compositor.updateShot(renamed)
        scheduleAutosave()
    }

    /// Removes a shot from the session preset. When the removed shot is on
    /// program, the compositor cuts to the adjacent shot — never a dead
    /// program (ARCHITECTURE.md, "Shot management") — so the model re-reads
    /// ``Compositor/activeShotID`` rather than second-guessing which shot
    /// that is. Then reconfigures, so an input referenced only by the removed
    /// shot (and not by the pickers) is stopped.
    ///
    /// - Parameter shotID: The id of the shot to remove.
    func removeShot(_ shotID: ShotID) async {
        guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
        shots.remove(at: index)
        compositor.removeShot(shotID: shotID)
        activeShotID = compositor.activeShotID
        scheduleAutosave()
        await reconfigure()
    }

    /// Adds a layer bound to the given input on top of the active shot's
    /// layer tree, then reconfigures so the input is running — a layer bound
    /// to a not-yet-started input contributes nothing until its first frame
    /// arrives, so the edit is visible on program the moment frames flow.
    ///
    /// - Parameter input: The input the new layer binds to.
    func addLayer(boundTo input: InputID) async {
        applyShotEdit { LayerTreeEdit.addingLayer(boundTo: input, to: $0) }
        await reconfigure()
    }

    /// Removes the layer at the given bottom-to-top index from the active
    /// shot, then reconfigures so an input no shot references anymore (and
    /// that is not the selected camera or display) is stopped.
    ///
    /// - Parameter index: The layer's index in the shot's `layers` array.
    func removeLayer(at index: Int) async {
        applyShotEdit { LayerTreeEdit.removingLayer(at: index, from: $0) }
        await reconfigure()
    }

    /// Moves the layer at the given bottom-to-top index one step through the
    /// active shot's stack.
    ///
    /// - Parameters:
    ///   - index: The layer's index in the shot's `layers` array.
    ///   - direction: Which way it moves through the stack.
    func moveLayer(at index: Int, _ direction: LayerTreeEdit.StackDirection) {
        applyShotEdit { LayerTreeEdit.movingLayer(at: index, direction, in: $0) }
    }

    /// Sets the frame of the active shot's layer at the given bottom-to-top
    /// index — its position and size in normalized, top-left-origin program
    /// coordinates. Applied live, so a slider drag is visible on program
    /// tick by tick.
    ///
    /// - Parameters:
    ///   - frame: The new normalized destination rect.
    ///   - index: The layer's index in the shot's `layers` array.
    func setLayerFrame(_ frame: CGRect, at index: Int) {
        applyShotEdit { LayerTreeEdit.settingFrame(frame, ofLayerAt: index, in: $0) }
    }

    /// Sets the opacity of the active shot's layer at the given bottom-to-top
    /// index. Applied live, like ``setLayerFrame(_:at:)``.
    ///
    /// - Parameters:
    ///   - opacity: The new opacity, `0`...`1`.
    ///   - index: The layer's index in the shot's `layers` array.
    func setLayerOpacity(_ opacity: Double, at index: Int) {
        applyShotEdit { LayerTreeEdit.settingOpacity(opacity, ofLayerAt: index, in: $0) }
    }

    /// The user-facing name of a discovered input, for the editor's layer
    /// rows — falls back to the raw identifier for an input that is no
    /// longer discovered (an edited layer can outlive its device).
    ///
    /// - Parameter id: The input's stable identifier.
    func inputName(for id: InputID) -> String {
        layerInputChoices.first { $0.id == id }?.name ?? id.rawValue
    }

    /// Applies one layer-tree edit to the shot currently selected in the
    /// switcher: transforms it, stores the edited shot back into the session
    /// preset (so it survives shot switches — GLOSSARY.md, "Preset"), pushes
    /// it through the compositor so the change is on program at the next
    /// tick, and schedules the debounced autosave so it reaches the project
    /// file. A no-op edit (out-of-range index, no shot selected, no actual
    /// change) touches nothing.
    private func applyShotEdit(_ edit: (Shot) -> Shot) {
        guard let activeShotID, let index = shots.firstIndex(where: { $0.id == activeShotID }) else { return }
        let edited = edit(shots[index])
        guard edited != shots[index] else { return }
        shots[index] = edited
        compositor.updateShot(edited)
        scheduleAutosave()
    }

    // MARK: Streaming

    /// The stream key stored for the current destination URL, or nil when none
    /// is stored (or the URL is empty). Read from secure storage so the
    /// streaming panel can prefill its key field on launch without the key
    /// ever passing through the project document. A read failure is reported
    /// and treated as "no stored key" — never a crash.
    ///
    /// - Returns: The stored stream key, or nil.
    func storedStreamKey() -> String? {
        guard let account = destinationAccount else { return nil }
        do {
            return try secureStorage.secret(forAccount: account)
        } catch {
            eventBus.error(
                "securestore.read",
                domain: .output,
                params: ["error": .string(String(describing: error))]
            )
            return nil
        }
    }

    /// Puts the program on air: resolves the destination URL to the streaming
    /// provider, stores the key in secure storage, and drives a
    /// ``StreamSession`` fed the compositor's program frames and the selected
    /// microphone — reusing the CLI's proven reconnect/stability/stats
    /// machinery (ARCHITECTURE.md, "Streaming the program"). One active
    /// session (the v1 rule): a second call while streaming is ignored.
    ///
    /// The stream key is used to build the ``Destination`` and to seed secure
    /// storage; it never becomes an event param, a log line, or part of the
    /// project document. An empty key streams keyless (some servers embed the
    /// key in the URL path) and clears any stored key for the URL.
    ///
    /// - Parameter streamKey: The RTMP(S) stream key the operator entered.
    func startStreaming(streamKey: String) async {
        guard streamSession == nil else { return }
        guard let url = URL(string: destinationURL), let scheme = url.scheme?.lowercased(), !destinationURL.isEmpty
        else {
            streamStatus = .error("Enter a valid rtmp:// or rtmps:// destination URL.")
            return
        }
        guard let provider = await outputs.provider(forScheme: scheme) else {
            streamStatus = .error("No streaming output serves '\(scheme)://' destinations (use rtmp:// or rtmps://).")
            return
        }

        // The key goes only into secure storage (or is cleared when blank),
        // keyed by the destination URL — a best-effort write: a Keychain error
        // is reported but does not block the stream, which still holds the key
        // in memory for this session.
        persistStreamKey(streamKey, forAccount: url.absoluteString)

        var microphone: (any Input)?
        if let micID = selectedMicrophoneID {
            microphone = await registry.input(withID: micID)
        }

        let configuration = StreamConfiguration(
            width: format.width,
            height: format.height,
            frameRate: format.frameRate,
            includesVideo: true,
            includesAudio: microphone != nil
        )
        let destination = Destination(url: url, streamKey: streamKey.isEmpty ? nil : streamKey)

        // Tee the program into a fresh stream: the drain in `start()` forwards
        // each composited frame here while `streamContinuation` is set.
        let (programStream, continuation) = AsyncStream.makeStream(of: CapturedFrame.self)
        streamContinuation = continuation

        let session = StreamSession(
            programVideo: programStream,
            audioInput: microphone,
            service: provider.makeStreamingService(configuration: configuration),
            destination: destination,
            configuration: configuration,
            policy: StreamSession.Policy(),
            clock: clock,
            eventBus: eventBus
        )
        streamSession = session
        streamStatus = .starting
        streamStats = nil

        streamTask = Task { [weak self] in
            do {
                _ = try await session.run()
                // Terminal status is set by the `stream.stopped` observer; the
                // task only tears the plumbing down.
            } catch {
                // A start-time failure (bad key, unreachable host) throws
                // before `stream.started`, so the observer never saw it.
                self?.eventBus.error(
                    "stream.start",
                    domain: .output,
                    params: [
                        "identifier": .string(ErrorIdentifier.connectionFailed.rawValue),
                        "message": .string(String(describing: error)),
                    ]
                )
                self?.streamStatus = .error(String(describing: error))
            }
            self?.teardownStream()
        }
    }

    /// Takes the program off air: requests a clean stop of the active session
    /// (flush compression, close the connection). The `stream.stopped` event
    /// settles the status; ``teardownStream()`` releases the plumbing when
    /// `run()` returns. A no-op when not streaming.
    func stopStreaming() async {
        await streamSession?.stop()
    }

    /// Stores the stream key for an account, or clears it when the key is
    /// empty — best effort. A secure-storage error is reported on the bus (no
    /// secret in the message) and swallowed: the in-memory key still drives
    /// this session's stream.
    ///
    /// - Parameters:
    ///   - streamKey: The key to store, or empty to clear the stored key.
    ///   - account: The secure-storage account (the destination URL).
    private func persistStreamKey(_ streamKey: String, forAccount account: String) {
        do {
            if streamKey.isEmpty {
                try secureStorage.removeSecret(forAccount: account)
            } else {
                try secureStorage.setSecret(streamKey, forAccount: account)
            }
        } catch {
            eventBus.error(
                "securestore.write",
                domain: .output,
                params: ["error": .string(String(describing: error))]
            )
        }
    }

    /// Releases the finished session's plumbing: finishes the program tee and
    /// drops the session references so a new stream can start.
    private func teardownStream() {
        streamContinuation?.finish()
        streamContinuation = nil
        streamSession = nil
        streamTask = nil
    }

    /// Updates ``streamStatus`` from a `stream.*` bus event — the event-driven
    /// status the CLI's `StreamSession` already emits (`stream.started`,
    /// `stream.reconnecting`, `stream.reconnected`, `stream.stopped`); no
    /// polling. Non-stream events are ignored.
    ///
    /// - Parameter event: An event drained from the bus.
    private func handleStreamStatusEvent(_ event: EventBusEvent) {
        switch event.name {
        case "stream.started", "stream.reconnected":
            streamStatus = .live
        case "stream.stats":
            // Bitrate arrives in bits per second; the panel shows kbps.
            let bitrate = event.params?["bitrate"].flatMap(Self.intValue) ?? 0
            let fps = event.params?["fps"].flatMap(Self.intValue) ?? 0
            streamStats = StreamStats(bitrateKbps: bitrate / 1000, fps: fps)
        case "stream.reconnecting":
            let attempt = event.params?["attempt"].flatMap(Self.intValue) ?? 0
            let maxAttempts = event.params?["maxAttempts"].flatMap(Self.intValue) ?? 0
            streamStatus = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
            streamStats = nil
        case "stream.stopped":
            // The session reports its outcome as the stop reason; a lost
            // connection past the reconnect budget is the failure case.
            let reason = event.params?["reason"].flatMap(Self.stringValue)
            streamStatus =
                reason == StreamSession.Outcome.connectionLost.rawValue
                ? .error("The connection was lost and not recovered.")
                : .stopped
            streamStats = nil
        default:
            break
        }
    }

    /// The secure-storage account for the current destination — the URL string
    /// when it parses, else nil (an empty or malformed URL has no stored key).
    private var destinationAccount: String? {
        guard !destinationURL.isEmpty, let url = URL(string: destinationURL) else { return nil }
        return url.absoluteString
    }

    /// The `Int` inside an event value, when it is one.
    private static func intValue(_ value: EventValue) -> Int? {
        if case .int(let int) = value { return int }
        return nil
    }

    /// The `String` inside an event value, when it is one.
    private static func stringValue(_ value: EventValue) -> String? {
        if case .string(let string) = value { return string }
        return nil
    }

    /// Records that the destination URL changed (the panel's text field):
    /// schedules the debounced autosave so the new URL reaches the project
    /// document, and reflects the URL's stored key by resetting a stale
    /// error/stopped status back to idle.
    func destinationURLChanged() {
        if !isStreaming { streamStatus = .idle }
        scheduleAutosave()
    }

    // MARK: Lifecycle

    /// Stops the compositor, the program drain, and every active input,
    /// flushing any pending autosave first so the last edits reach disk.
    func stop() async {
        await stopStreaming()
        streamStatusTask?.cancel()
        streamStatusTask = nil
        if autosaveTask != nil { saveProject() }
        programTask?.cancel()
        programTask = nil
        compositor.stop()
        for input in activeInputs.values {
            await input.stop()
        }
        activeInputs.removeAll()
        eventBus.shutdown()
    }

    /// Loads the project document at boot, adopting its first preset as the
    /// session preset and pointing the pickers at the devices its layers
    /// reference; with no file (or a file holding no presets), it leaves the
    /// session preset unseeded — ``establishSessionPreset()`` seeds it from
    /// the built-in arrangement on the first configuration pass — and
    /// defaults the pickers to the first discovered devices. An unreadable
    /// file is reported and set aside, never silently overwritten (see
    /// ARCHITECTURE.md, "Project save/load").
    private func loadProject() {
        let path = store.fileURL.path(percentEncoded: false)
        var loadedPreset: Preset?
        do {
            if let project = try store.load() {
                loadedPreset = project.presets.first
                otherPresets = Array(project.presets.dropFirst())
                // Restore the destination URL (the key stays in secure
                // storage, read lazily when the panel prefills its field).
                if let url = project.destination?.url { destinationURL = url.absoluteString }
            }
        } catch {
            eventBus.error(
                "project.load",
                domain: .composition,
                params: ["path": .string(path), "error": .string(String(describing: error))]
            )
            do {
                let setAside = try store.setAsideUnreadableFile()
                eventBus.event(
                    "project.setAside",
                    domain: .composition,
                    params: ["path": .string(setAside.path(percentEncoded: false))]
                )
            } catch {
                eventBus.error(
                    "project.setAside",
                    domain: .composition,
                    params: ["path": .string(path), "error": .string(String(describing: error))]
                )
            }
        }

        guard let loadedPreset else {
            // A fresh project: default to the first discovered devices; the
            // first configuration pass seeds the built-in arrangement from
            // whatever actually starts.
            selectedDisplayID = displays.first?.id
            selectedCameraID = cameras.first?.id
            return
        }

        presetID = loadedPreset.id
        presetName = loadedPreset.name
        shots = loadedPreset.shots
        hasSessionPreset = true

        // The pickers reflect the loaded document: the first referenced input
        // of each kind that is currently discovered plays that built-in role.
        // A referenced input that is not discovered stays bound — its layers
        // contribute nothing until it returns (or the operator removes and
        // re-adds the layer in the layer-tree editor).
        let referenced = shots.flatMap { $0.layers.map(\.input) }
        boundCameraID = referenced.first { id in cameras.contains { $0.id == id } }
        boundDisplayID = referenced.first { id in displays.contains { $0.id == id } }
        selectedCameraID = boundCameraID
        selectedDisplayID = boundDisplayID
        eventBus.event(
            "project.loaded",
            domain: .composition,
            params: [
                "path": .string(path),
                "presets": .int(1 + otherPresets.count),
                "shots": .int(shots.count),
            ]
        )
    }

    /// Completes the first configuration pass: when no project file supplied
    /// a preset, seeds one from the built-in ``ProgramLayout`` arrangement
    /// (using only the inputs that actually started) and saves the fresh
    /// project immediately so the file exists from first launch; then loads
    /// the session preset into the compositor, which cuts to its first shot
    /// (the active shot is session state, never part of the document).
    private func establishSessionPreset() {
        if !hasSessionPreset {
            let displayID = selectedDisplayID.flatMap { activeInputs[$0] != nil ? $0 : nil }
            let cameraID = selectedCameraID.flatMap { activeInputs[$0] != nil ? $0 : nil }
            shots = ProgramLayout.shots(displayID: displayID, cameraID: cameraID)
            boundDisplayID = displayID
            boundCameraID = cameraID
            hasSessionPreset = true
            eventBus.event(
                "project.seeded",
                domain: .composition,
                params: ["path": .string(store.fileURL.path(percentEncoded: false))]
            )
            saveProject()
        }
        compositor.loadPreset(Preset(id: presetID, name: presetName, shots: shots))
        activeShotID = shots.first?.id
    }

    /// Rebinds every layer bound to one device to another across all the
    /// session preset's shots — how a picker change recasts which device
    /// plays the built-in role — pushing each changed shot through the
    /// compositor so the recast is on program at the next tick.
    ///
    /// - Parameters:
    ///   - previous: The device the role's layers are currently bound to, or
    ///     nil when the role was never cast (nothing to rebind).
    ///   - input: The newly chosen device.
    /// - Returns: Whether any shot changed.
    private func rebindLayers(from previous: InputID?, to input: InputID) -> Bool {
        guard let previous, previous != input else { return false }
        var changed = false
        for index in shots.indices {
            let rebound = LayerTreeEdit.rebindingLayers(boundTo: previous, to: input, in: shots[index])
            guard rebound != shots[index] else { continue }
            shots[index] = rebound
            compositor.updateShot(rebound)
            changed = true
        }
        if changed {
            eventBus.event(
                "preset.rebound",
                domain: .composition,
                params: ["from": .string(previous.rawValue), "to": .string(input.rawValue)]
            )
        }
        return changed
    }

    /// Saves the project document now — the session preset (with its live
    /// layer-tree edits) first, the loaded document's other presets preserved
    /// after it — cancelling any pending autosave. A save that cannot write
    /// is reported on the bus and the session continues: the edits are still
    /// live on program, only unsaved.
    private func saveProject() {
        guard hasSessionPreset else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        // The destination URL joins the document (project format v2); its
        // stream key is excluded — it lives only in secure storage.
        let destination = URL(string: destinationURL).flatMap {
            destinationURL.isEmpty ? nil : ProjectDestination(url: $0)
        }
        let project = Project(
            presets: [Preset(id: presetID, name: presetName, shots: shots)] + otherPresets,
            destination: destination
        )
        do {
            try store.save(project)
            eventBus.event(
                "project.saved",
                domain: .composition,
                params: ["path": .string(store.fileURL.path(percentEncoded: false))]
            )
        } catch {
            eventBus.error(
                "project.save",
                domain: .composition,
                params: [
                    "path": .string(store.fileURL.path(percentEncoded: false)),
                    "error": .string(String(describing: error)),
                ]
            )
        }
    }

    /// Schedules the debounced autosave: the write lands one second after the
    /// last edit, so a slider drag's many per-gesture edits coalesce into a
    /// single save (the same reasoning that keeps successful `updateShot`
    /// calls off the event bus; see ARCHITECTURE.md, "Project save/load").
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return  // Cancelled: a newer edit rescheduled, or a save flushed it.
            }
            self?.saveProject()
        }
    }
}

/// A plain, `@MainActor` holder for the latest program pixel buffer: the
/// writer (the ``EngineModel``'s program drain) and the reader (the
/// `MTKView` coordinator) share one instance, so the preview samples the
/// program at display rate without pushing 30 fps of state changes through
/// SwiftUI.
@MainActor
final class ProgramFrameRelay {
    /// The most recent program frame's pixel buffer, or nil before the
    /// first frame. Under the frame ownership rule the relay is the one
    /// holder; the coordinator only reads it to draw.
    var latest: CVPixelBuffer?

    /// Creates an empty relay.
    init() {}
}

/// A no-op `ToolRegistering`: the app does not host the MCP tool surface
/// (the daemon does), but the shared `PlugInContext` still requires the seam.
private struct UnusedToolRegistering: ToolRegistering {
    func register(_ tool: any Tool) async throws {}
}
