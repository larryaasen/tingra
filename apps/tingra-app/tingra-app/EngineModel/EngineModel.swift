//
//  EngineModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Observation
import Synchronization
import TingraAudio
import TingraCapturePlugIns
import TingraComposition
import TingraEffectPlugIns
import TingraEventBus
import TingraGeneratorPlugIns
import TingraHost
import TingraJSONRPC
import TingraMediaPlugIns
import TingraMonitorPlugIns
import TingraOutputPlugIns
import TingraPlugInKit
import TingraRecordingPlugIns
import UniformTypeIdentifiers

/// The app's engine model: the one `@Observable` that boots the host,
/// activates the first-party plug-ins, and drives the compositor for the
/// on-screen program preview. It mirrors the CLI's engine wiring but ends
/// in the ``Compositor`` and an `MTKView` rather than a streaming service
/// (GLOSSARY.md, "Engine"). `@MainActor`: the UI reads its state directly,
/// and every plug-in and compositor call is made from here.
@MainActor
@Observable
final class EngineModel {
    /// One selectable input as the pickers and media-role lists show it.
    struct InputChoice: Identifiable, Hashable {
        /// The input's stable identifier.
        let id: InputID

        /// The user-facing name.
        let name: String

        /// The input's provenance, which keeps the mixer's seed from putting
        /// a synthesized tone on air (``MixerStrip/seed(from:)``). No
        /// default value: a wrong kind would be silent bad data.
        let kind: InputKind
    }

    /// One registered audio effect as the strip's Add Effect menu offers it,
    /// snapshotted from the effect registry at boot so the UI never awaits
    /// the actor per draw.
    struct AudioEffectChoice: Identifiable, Equatable {
        /// The effect's stable identifier.
        let id: EffectID

        /// The user-facing effect name, as the provider declares it.
        let name: String

        /// The parameters the effect declares, in display order.
        let parameters: [Parameter]
    }

    /// One registered video effect as the layer editor's Add Effect menu
    /// offers it — the video mirror of ``AudioEffectChoice``.
    struct VideoEffectChoice: Identifiable, Equatable {
        /// The effect's stable identifier.
        let id: EffectID

        /// The user-facing effect name, as the provider declares it.
        let name: String

        /// The parameters the effect declares, in display order.
        let parameters: [Parameter]
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

        /// Stop was clicked and the session is ending. Set by the app, since
        /// the session reports nothing until `stream.stopped`; a late
        /// `started` or `reconnected` does not move the status on.
        case stopping

        /// The stream stopped cleanly (Stop, or an elapsed duration).
        case stopped

        /// The stream ended on a failure — a start-time rejection (bad key,
        /// unreachable host) or a connection lost past the reconnect budget.
        /// Carries a developer-facing message (never a secret).
        case error(String)

        /// Whether a session is in flight: starting, live, reconnecting, or
        /// stopping. A stopping session still holds the destinations and
        /// the program format, so a second start is refused until it closes.
        var isActive: Bool {
            switch self {
            case .starting, .live, .reconnecting, .stopping: true
            case .idle, .stopped, .error: false
            }
        }
    }

    /// The live state of the app's local recording, from its own session's
    /// `recording.*` events. Separate from ``StreamStatus``: it runs
    /// independently of the stream (ARCHITECTURE.md, "Recording in the app").
    enum RecordingStatus: Equatable {
        /// Not recording.
        case idle

        /// Opening the file — after Record, before `recording.started`.
        case starting

        /// Writing: the program is going to disk.
        case recording

        /// Flushing and closing the file after Stop, so it is playable.
        case finalizing

        /// The recording ended on a failure — it could not be opened (an
        /// unwritable folder, a volume without room) or a write failed
        /// partway through. Carries a developer-facing message.
        case error(String)
    }

    /// A snapshot of the live stream's delivery counters, which the panel
    /// shows beside the Live label.
    struct StreamStats: Equatable {
        /// The current send bitrate in kilobits per second.
        let bitrateKbps: Int

        /// The current delivered frame rate.
        let fps: Int
    }

    /// How often the app's stream writes `stream.stats` to the log, in
    /// seconds. The panel reads the once-a-second live statistics instead
    /// (EVENTS.md, "Stream statistics: the readout and the log").
    static let streamStatsLogIntervalSeconds = 60

    /// One destination leg's live state, from the session's per-leg status
    /// events: what its row of the streaming panel shows on air
    /// (ARCHITECTURE.md, "Multiple destinations").
    enum DestinationState: Equatable {
        /// Publishing to this destination.
        case live

        /// This destination dropped and a reconnect attempt is in flight.
        case reconnecting(attempt: Int, maxAttempts: Int)

        /// This destination refused the connection at start, so it is not
        /// being streamed to; the rest of the session is unaffected.
        case rejected

        /// This destination dropped and was not recovered within its
        /// reconnect budget. The session continues on the others.
        case lost
    }

    /// The discovered cameras, for the sidebar's Cameras section, the Add
    /// Shot menu, and a fresh project's seed.
    var cameras: [InputChoice] = []

    /// The discovered displays, for the sidebar's Displays section, the Add
    /// Shot menu, and a fresh project's seed.
    var displays: [InputChoice] = []

    /// The window inputs the project holds, for the sidebar's Windows
    /// section and the Add Shot menu — added by the operator, not
    /// discovered (ARCHITECTURE.md, "Window capture").
    var windowInputs: [InputChoice] = []

    /// Every discovered input that produces **audio**, seeding the mixer's
    /// channel strips. Filtered on ``Input/media``, so an audio generator
    /// qualifies (ARCHITECTURE.md, "The `Input` media capability").
    var audioInputs: [InputChoice] = []

    /// Every discovered input that produces **video**, for the layer-tree
    /// editor's add-layer choices. Filtered on ``Input/media`` like
    /// ``audioInputs``, which admits the video generators.
    var videoInputs: [InputChoice] = []

    /// Every input's name as discovery last reported it, keyed by id, so a
    /// picker can label a selection whose device has gone away: a `Picker`
    /// selection matching no tag is undefined (``inputName(for:)``).
    var lastKnownInputNames: [InputID: String] = [:]

    /// The parameters each registered input declares, keyed by id (PLUGINS.md,
    /// Decision 15), snapshotted with every device-list rebuild so a strip's
    /// Input Settings button appears without awaiting the actor per draw.
    var declaredInputParameters: [InputID: [Parameter]] = [:]

    /// The inputs' parameter values, by input id: the document's
    /// `inputParameters` key, applied through `Input.setParameters` on load
    /// and on registration, edited by ``setInputParameter(_:forKey:ofInput:)``.
    /// An entry for an input this Mac lacks is kept and written back.
    var inputParameters: [InputID: [String: JSONValue]] = [:]

    /// The values a device keeps for itself, by input id, such as a UVC
    /// camera's brightness (`Input.currentParameters`, docs/UVC.md). Shown
    /// until the project stores a value; never written to the document.
    var deviceInputParameters: [InputID: [String: JSONValue]] = [:]

    /// The last application of an edited input payload, chained so edits
    /// made at gesture rate reach the input in order and a stale value is
    /// never applied last.
    @ObservationIgnored var inputParameterApplyTask: Task<Void, Never>?

    /// The mixer's channel strips (GLOSSARY.md, "Channel strip"): the active
    /// preset's authored audio channels merged with live discovery
    /// (``MixerStrip/strips(channels:discovered:)``). A strip whose device is
    /// absent stays, dormant (ARCHITECTURE.md, "Per-strip routing").
    var mixerStrips: [MixerStrip] = []

    /// The registered audio effects the strips' Add Effect menus offer,
    /// in the registry's stable listing order — snapshotted at boot
    /// (ARCHITECTURE.md, "Audio effect chains").
    private(set) var audioEffectChoices: [AudioEffectChoice] = []

    /// The audio output devices the monitor picker offers, refreshed from
    /// the monitor's device-update stream as devices come and go — never
    /// polled.
    var monitorDevices: [AudioMonitorDevice] = []

    /// The device the operator monitors through, or nil for no monitoring.
    /// Nil on a fresh install: monitoring beside a live microphone is a
    /// feedback howl, so it is opt-in (ARCHITECTURE.md, "The monitor path").
    var monitorDeviceUID: String?

    /// The selected device's name as discovery last reported it, or nil: the
    /// picker's label while ``monitorDevices`` cannot resolve the selection,
    /// before the first device list arrives or while the device is unplugged.
    var monitorDeviceName: String?

    /// The monitor level — the operator's own listening volume. It scales
    /// only what the monitor plays and never the program mix, so moving it
    /// cannot change what viewers hear.
    var monitorLevel: Double = MonitorPreferences.defaultLevel

    /// Whether the monitor is muted: the control room cut. The device and
    /// ``monitorLevel`` stay as they were, and the program mix is untouched.
    var isMonitorMuted = false

    /// Whether the master is muted: the program's sound off air while its
    /// picture keeps going (GLOSSARY.md, "Master mute"). Session state, never
    /// saved: a forgotten master mute is a silent recording nobody hears.
    var isMasterMuted = false

    /// Whether the monitor is currently playing. False while the selected
    /// device is disconnected, so the master strip can tell "not monitoring"
    /// from "monitoring through a device that has gone away".
    var isMonitoring = false

    /// The registered video effects the layer editor's Add Effect menu
    /// offers, in the registry's stable listing order (ARCHITECTURE.md,
    /// "Per-layer video effects").
    private(set) var videoEffectChoices: [VideoEffectChoice] = []

    /// The destinations the streaming panel edits, persisted in the project
    /// document; the stream keys live in secure storage (ARCHITECTURE.md,
    /// "Streaming the program" and "Multiple destinations"). Going live
    /// sends the program to every enabled destination with a usable URL.
    var destinations: [DestinationEdit] = []

    /// The destination templates the registered streaming outputs offer the
    /// Streaming settings pane, sorted by name and snapshotted at boot
    /// (DESTINATIONS.md, "Destination templates").
    private(set) var destinationTemplates: [DestinationTemplate] = []

    /// Whether at least one destination is ready to stream — what the Start
    /// control enables on.
    var hasStreamableDestination: Bool {
        destinations.contains(where: \.isStreamable)
    }

    /// The live streaming status, driven entirely by the `stream.*` events on
    /// the bus (never a poll) — what the Start/Stop control reflects.
    var streamStatus: StreamStatus = .idle

    /// The latest delivery stats from the session's live statistics, or nil
    /// when not streaming. With several destinations this is the first live
    /// leg's, never an average; each leg's own is in ``destinationStats``.
    var streamStats: StreamStats?

    /// Whether the stream on air is being delivered well, from the same
    /// once-a-second readings as ``streamStats`` — what ``streamTrouble``
    /// judges.
    var streamHealth = StreamHealth()

    /// What is wrong with the stream on air, or nil while it is healthy or
    /// not on air — what the status bar shows beside Live
    /// (``StreamHealth``).
    var streamTrouble: StreamHealth.Trouble? {
        guard streamStatus == .live else { return nil }
        return streamHealth.trouble(destinationStates: destinationStates)
    }

    /// When the current stream went on air (the session's `stream.started`
    /// date), or nil when not streaming. It holds through a reconnect, and
    /// the status bar draws its elapsed time from it at display cadence.
    var streamStartedAt: Date?

    /// Each streaming destination's latest delivery stats, keyed by
    /// destination id, for the panel's per-destination rows. Cleared when
    /// the stream ends.
    var destinationStats: [ProjectDestinationID: StreamStats] = [:]

    /// Each streaming destination's live state, keyed by destination id —
    /// how a row shows that one destination is reconnecting or gone while the
    /// others stay live. Empty when not streaming.
    var destinationStates: [ProjectDestinationID: DestinationState] = [:]

    /// The live recording status, driven entirely by the `recording.*` events
    /// on the bus (never a poll) — what the Record control reflects.
    var recordingStatus: RecordingStatus = .idle

    /// Where the current recording is being written, or nil when not
    /// recording — what the panel names beside the elapsed time.
    var recordingURL: URL?

    /// When the current recording started on the master clock, or nil when
    /// not recording. The panel draws its elapsed time from this at display
    /// cadence rather than having it pushed per tick.
    var recordingStartedAt: Date?

    /// The folder recordings are written into, from machine-local preferences
    /// (ARCHITECTURE.md, "Recording in the app").
    var recordingFolder: URL

    /// The container format recordings are muxed into.
    var recordingContainer: RecordingFile.Container

    /// The video codec recordings are compressed with, from machine-local
    /// preferences (ARCHITECTURE.md, "Compression settings in the app").
    var recordingVideoCodec: StreamConfiguration.VideoCodec

    /// The audio bit rate recordings are compressed at, in bits per second —
    /// one of ``CompressionChoices/audioBitRates``.
    var recordingAudioBitsPerSecond: Int

    /// The audio bit rate the stream is compressed at, in bits per second —
    /// one of ``CompressionChoices/audioBitRates``.
    var streamAudioBitsPerSecond: Int

    /// How much recording the chosen folder's volume still holds at the
    /// program's settings, or nil when it cannot be measured: the same
    /// reading the pre-flight check refuses on.
    var recordingCapacity: RecordingCapacity?

    /// The recording file being written right now, or nil, from
    /// `recording.started` until `recording.stopped` finalizes it. The
    /// Recordings tab marks it not yet playable, and ``trashRecording(at:)``
    /// refuses it (ARCHITECTURE.md, "The Recordings tab").
    var fileBeingRecorded: URL?

    /// Bumped whenever Tingra changes the recordings folder or its contents
    /// (a take starting or finalized, a trash, a folder choice), so the
    /// Recordings tab re-reads the listing rather than watching the folder.
    var recordingRevision = 0

    /// The folder snapshots are saved into, from machine-local preferences
    /// (ARCHITECTURE.md, "Snapshots").
    var snapshotFolder: URL

    /// Whether a stream or a recording holds the Mac awake, from
    /// machine-local preferences (CLOCK.md, "System sleep and App Nap"). A
    /// change takes effect at once, mid-session too (``KeepAwakeSwitch``).
    private(set) var keepsMacAwake: Bool

    /// Bumped whenever Tingra changes the snapshots folder or its contents
    /// (a save, a trash, a folder choice), so the Snapshots tab re-reads the
    /// listing rather than watching the folder.
    var snapshotRevision = 0

    /// The badge the last snapshot request put on its monitor, or nil when
    /// none is showing (``SnapshotFeedback``).
    var snapshotFeedback: SnapshotFeedback?

    /// The compression settings a recording is written with: the program's
    /// geometry and rate, as the free-space estimate uses, so the panel and
    /// the pre-flight check cannot disagree. The video bit rate follows the
    /// format and the operator's codec (``CompressionChoices``).
    var recordingConfiguration: StreamConfiguration {
        StreamConfiguration(
            width: format.width,
            height: format.height,
            frameRate: format.frameRate,
            videoCodec: recordingVideoCodec,
            videoBitsPerSecond: CompressionChoices.videoBitsPerSecond(
                width: format.width, height: format.height, frameRate: format.frameRate,
                codec: recordingVideoCodec),
            audioBitsPerSecond: recordingAudioBitsPerSecond,
            includesVideo: true,
            includesAudio: true
        )
    }

    /// The compression settings every leg of the stream is sent with: the
    /// program's geometry and rate, H.264 (the codec every destination
    /// accepts), and a video bit rate that follows the format
    /// (ARCHITECTURE.md, "The program format as a project setting").
    var streamConfiguration: StreamConfiguration {
        StreamConfiguration(
            width: format.width,
            height: format.height,
            frameRate: format.frameRate,
            videoBitsPerSecond: StreamConfiguration.recommendedVideoBitsPerSecond(
                width: format.width, height: format.height, frameRate: format.frameRate),
            audioBitsPerSecond: streamAudioBitsPerSecond,
            includesVideo: true,
            includesAudio: true
        )
    }

    /// Whether a recording is currently starting or writing — so the control
    /// shows Stop and the folder locks.
    var isRecording: Bool {
        switch recordingStatus {
        case .starting, .recording: return true
        case .idle, .finalizing, .error: return false
        }
    }

    /// Whether Stop Recording was clicked and the file is still being closed,
    /// so the control reads Finishing… and cannot be clicked.
    var isFinishingRecording: Bool {
        recordingStatus == .finalizing
    }

    /// Whether a stream is currently starting, live, reconnecting, or
    /// stopping — so the destination fields lock and a format change or a
    /// project switch is refused (``StreamStatus/isActive``).
    var isStreaming: Bool {
        streamStatus.isActive
    }

    /// Whether Stop was clicked and the stream is still closing — so the
    /// control reads Stopping… and cannot be clicked again.
    var isStoppingStream: Bool {
        streamStatus == .stopping
    }

    /// The project's presets, in switcher order (ARCHITECTURE.md, "Multiple
    /// presets in the UI"). ``syncActivePreset()`` refreshes the active one
    /// from ``shots`` before every save, switch, and duplicate.
    var presets: [Preset] = []

    /// The id of the active preset, which the shot switcher and layer-tree
    /// editor operate within. Session state: at launch the app adopts the
    /// document's first preset, never a persisted "active" field.
    var activePresetID: PresetID? {
        didSet { recordSessionPosition() }
    }

    /// The active preset's name, or nil before a preset is active — what the
    /// window's subtitle shows beneath the project's name (``TingraApp``).
    var activePresetName: String? {
        presets.first { $0.id == activePresetID }?.name
    }

    /// The active preset's shots, in switcher order (ARCHITECTURE.md, "The
    /// shot bank"). The live session copy: edits land here first, and the
    /// authored ones flow back into ``presets``. A transient shot
    /// (``ShotOrigin/automatic``) is not saved (``reconcileTransientShots()``).
    var shots: [Shot] = []

    /// The id of the shot on program, or `nil` when there are no shots.
    /// Session state, never in the project document, remembered
    /// machine-locally (``recordSessionPosition()``).
    var activeShotID: ShotID? {
        didSet { recordSessionPosition() }
    }

    /// The id of the shot staged on preview, or `nil` when nothing is staged.
    /// Session state like ``activeShotID`` (ARCHITECTURE.md, "The preview
    /// bus"). Clearing it also empties ``previewRelay``, so the monitor does
    /// not keep drawing the last staged frame.
    var previewShotID: ShotID? {
        didSet {
            previewRelay.setAccepting(previewShotID != nil)
            recordSessionPosition()
        }
    }

    /// Whether the program is faded to black, picture and sound (GLOSSARY.md,
    /// "Fade to black"). The latch, flipped the moment the operator acts
    /// rather than tracking either ramp. Session state, never saved.
    var isFadedToBlack = false

    /// The inputs the engine is currently running, in name order: the
    /// multiview's tiles (GLOSSARY.md, "Multiview"). Never what is merely
    /// discovered, so opening a monitoring window starts no device.
    var multiviewInputs: [InputChoice] = []

    /// The inputs on program, for the multiview's tally lamps (GLOSSARY.md,
    /// "Tally"). Mirrored from ``Compositor/programInputIDs``, which unions
    /// the outgoing shot's inputs during a transition.
    var programInputIDs: Set<InputID> = []

    /// The inputs contributing to the shot staged on preview: the green half
    /// of the tally (see ``programInputIDs``). Transitions are program-only,
    /// so there is nothing to union here.
    var previewInputIDs: Set<InputID> = []

    /// The shot on program, as the switcher highlights it — `nil` when there
    /// are no shots, or while a preset switch holds a snapshot from outside
    /// the pool (see ``programShot``).
    var activeShot: Shot? {
        shots.first { $0.id == activeShotID }
    }

    /// The shot on program, as the program monitor's caption names it: the
    /// active shot, or the shot a preset switch holds on program from outside
    /// the loaded pool (``Compositor/loadPreset(_:)``). `nil` when the
    /// program is background-only. Read through the compositor, not stored:
    /// every change into or out of a hold already reassigns ``activeShotID``.
    var programShot: Shot? {
        if let activeShot { return activeShot }
        let rendering = compositor.programShot
        return rendering.name.isEmpty ? nil : rendering
    }

    /// The shot staged on preview, as the preview monitor's caption names it,
    /// or `nil` while nothing is staged. ``shots`` holds the transient shot
    /// ``stagePreview(showing:)`` makes as well as the authored ones.
    var previewShot: Shot? {
        shots.first { $0.id == previewShotID }
    }

    /// The shot the layer-tree editor follows, with its tally: the shot
    /// staged on preview, or the shot on program when nothing is staged
    /// (``EditedShot``). `nil` when neither bus carries a shot from ``shots``.
    var editedShot: EditedShot? {
        EditedShot.following(shots: shots, previewShotID: previewShotID, activeShotID: activeShotID)
    }

    // MARK: Media

    /// The files the project holds as media, in the order added
    /// (ARCHITECTURE.md, "Media inputs and the Library's Media tab"). An item
    /// whose file is missing stays listed and dormant.
    var media: [ProjectMedia] = []

    /// Movie and audio file durations by item, loaded as each registers, so
    /// the Library shows a file's length where it shows a still's size.
    var mediaDurations: [MediaID: TimeInterval] = [:]

    /// Each media item's picture size in pixels, read from the file as it
    /// registers with its orientation applied, so a layer can be fitted
    /// before the input delivers a frame (``newLayerFrame(forInput:)``).
    var mediaSizes: [MediaID: CGSize] = [:]

    /// The content types the registered media providers open — what the
    /// Library's importer and drop target accept. Snapshotted after the
    /// plug-ins activate.
    private(set) var mediaContentTypes: [UTType] = []

    /// The media registry the media plug-in registers its providers into and
    /// the model resolves each added file through.
    @ObservationIgnored let mediaRegistry = MediaRegistry()

    // MARK: Windows

    /// The windows the project holds as inputs, in the order added
    /// (ARCHITECTURE.md, "Window capture"). A record whose window is not open
    /// stays listed, its input waiting for the window.
    var windows: [ProjectWindow] = []

    /// Each window's size in points as the picker listed it when added, so a
    /// new layer can be fitted before the input delivers a frame
    /// (``newLayerFrame(forInput:)``). Session state: a window loaded from a
    /// project is measured from its first frame instead.
    var windowSizes: [InputID: CGSize] = [:]

    /// Whether the Add Window sheet is up (``WindowPickerSheet``). Held here
    /// rather than in a view because several surfaces open it and one view,
    /// ``ContentView``, presents it.
    var isWindowPickerPresented = false

    // MARK: Applications

    /// The applications the project holds as audio inputs, in the order
    /// added (ARCHITECTURE.md, "Application audio"). A record whose
    /// application is not running stays listed, its input waiting for it.
    var applications: [ProjectApplication] = []

    /// Whether the Add Application sheet is up (``ApplicationPickerSheet``).
    /// Session state held here, like ``isWindowPickerPresented``, so the
    /// sidebar opens it and ``ContentView`` presents it.
    var isApplicationPickerPresented = false

    // MARK: Layer editing session state

    /// The selected layer's index in the followed shot's bottom-to-top
    /// `layers` array, or `nil` for no selection. Session state, held here
    /// because several surfaces use it. Read it through ``selectedLayer``,
    /// which validates it: a stale index is no selection, never a crash.
    var selectedLayerIndex: Int?

    /// Whether a resize keeps the selected layer's proportion: the
    /// inspector's lock, which the monitor's handles honor too. On by
    /// default, since a stretch is usually the accident. Session state.
    var holdsLayerAspect = true

    /// Whether the inspector's layer monitor is disclosed. Closed by default
    /// and not drawn while closed: a monitor at display rate is a cost worth
    /// paying only while judging an effect. Session state.
    var isLayerMonitorDisclosed = false

    /// The main window's undo manager, so every layer-tree edit can register
    /// the shot it replaced (ARCHITECTURE.md, "Direct manipulation,
    /// drag-to-reorder, and undo in the layer-tree editor"). The window owns it.
    weak var undoManager: UndoManager?

    /// The followed shot as it was when the gesture in progress began, or
    /// nil between gestures. While set, ``applyShotEdit(_:_:)`` registers
    /// nothing: ``endLayerGesture(_:)`` registers the drag as one undo step.
    var layerGestureSnapshot: Shot?

    /// The transition kind the next shot switcher tap takes with
    /// (GLOSSARY.md, "Transition"). Session state, remembered machine-locally
    /// (``recordSessionPosition()``). Starts on ``TakeTransitionKind/default``,
    /// so each take uses the taken shot's own ``Shot/defaultTransition``
    /// until overridden (ARCHITECTURE.md, "Per-shot default transitions").
    var takeTransitionKind: TakeTransitionKind = .default {
        didSet { recordSessionPosition() }
    }

    /// The frame edge the next wipe reveals the incoming shot from, read
    /// only while ``takeTransitionKind`` is ``TakeTransitionKind/wipe``.
    /// Session state, remembered like ``takeTransitionKind``.
    var wipeEdge: WipeEdge = .left {
        didSet { recordSessionPosition() }
    }

    /// The built-in shader the next shader transition reveals the incoming
    /// shot with, read only while ``takeTransitionKind`` is
    /// ``TakeTransitionKind/shader``; remembered like ``takeTransitionKind``.
    var shaderName: TransitionShader = .iris {
        didSet { recordSessionPosition() }
    }

    /// The length, in seconds, of the next timed take: the panel's one rate
    /// knob. Every dissolve, wipe, and shader transition runs this long,
    /// including a taken shot's ``Shot/defaultTransition``; a cut ignores it.
    /// Remembered like ``takeTransitionKind``; ``setTakeTransitionDuration(_:)``
    /// clamps it to ``takeTransitionDurationRange``.
    var takeTransitionDuration: TimeInterval = Transition.defaultDissolveDuration {
        didSet { recordSessionPosition() }
    }

    /// What picking a shot does: stage it on preview (the default), or take
    /// it to program (ARCHITECTURE.md, "Taking a shot with one click").
    /// Session state, remembered like ``takeTransitionKind``.
    var switchingMode: SwitchingMode = .stageOnPreview {
        didSet { recordSessionPosition() }
    }

    /// The lengths a timed take may have: instant-as-a-tick (the compositor
    /// rounds a zero to its first tick) up to ten seconds, past which a
    /// transition is a hold, not a switch.
    static let takeTransitionDurationRange: ClosedRange<TimeInterval> = 0...10

    /// The latest program frame, handed to the preview view to draw. Held
    /// in a plain relay (not observed) so the ~30 fps program does not churn
    /// SwiftUI — the `MTKView` samples it at display rate (CLOCK.md).
    @ObservationIgnored let programRelay = ProgramFrameRelay()

    /// The latest preview frame, for the preview monitor to sample at display
    /// cadence (GLOSSARY.md, "Preview"). Emptied whenever ``previewShotID``
    /// goes nil, so a cleared preview reads as empty, not frozen.
    @ObservationIgnored let previewRelay = ProgramFrameRelay()

    /// The latest mix tick's meter readings: the meter drain writes it and
    /// ``meterDisplayLink`` samples it at display cadence, outside SwiftUI
    /// observation (ARCHITECTURE.md, "Per-strip meters").
    @ObservationIgnored let meterRelay: MeterRelay

    /// The one display link every meter and peak readout shares, reading
    /// ``meterRelay`` once a frame outside SwiftUI's graph (ARCHITECTURE.md,
    /// "Meters off the SwiftUI clock"). Idle until a meter is in a window.
    @ObservationIgnored let meterDisplayLink: MeterDisplayLink

    /// The same mix ticks as app-tier plug-ins follow them: a subscribed
    /// connection is sent its window of them at most ten times a second
    /// (`tingra/meters`; PLUGINS.md, Decision 18).
    @ObservationIgnored let meterFeed = MeterFeed()

    /// The host event bus. Its log sinks drain it (``start(launch:)``): the
    /// host's `FileSink` on ``logFile``, and the ``ConsoleEventSink`` for a
    /// developer run or the host's `OSLogSink` (EVENTS.md, "Sinks"). Not
    /// `private`: the UI code that executes an action reports its `tap`
    /// through `model.eventBus.tap(...)` (EVENTS.md, "The `tap` convention").
    @ObservationIgnored let eventBus = EventBus()

    /// The app's one log file, `~/Library/Logs/Tingra/Tingra.log`. One
    /// locator for the file sink and the Logging settings pane, so they
    /// cannot name different files (EVENTS.md, "File sink").
    @ObservationIgnored let logFile = LogFile()

    /// The master clock (see CLOCK.md).
    @ObservationIgnored let clock = HostClock()

    /// The input registry the plug-ins register into.
    @ObservationIgnored lazy var registry = InputRegistry(eventBus: eventBus)

    /// The authorization seam the permissions are read through — the real
    /// TCC reads in production, a scripted answer in tests.
    @ObservationIgnored private let authorization: any AuthorizationChecking

    /// Reads the system default microphone's input id, which a fresh
    /// project's mixer seeds its one strip on
    /// (``MixerStrip/seed(from:preferring:)``). A fixed answer in tests.
    @ObservationIgnored let defaultMicrophoneID: @Sendable () -> InputID?

    /// Where each system permission stands: the Permissions settings pane's
    /// model, refreshed on every app activation so a grant made in System
    /// Settings starts the inputs it unblocks (``applyNewlyGranted(_:)``).
    @ObservationIgnored private(set) lazy var permissions = PermissionsModel(
        authorization: authorization, eventBus: eventBus)

    /// The output registry the streaming plug-in registers into — the same
    /// seam the CLI resolves a destination scheme against
    /// (`OutputRegistry.provider(forScheme:)`).
    @ObservationIgnored let outputs = OutputRegistry()

    /// The effect registry the effect plug-in registers into — where a
    /// strip's persisted chain resolves each `EffectID` to its provider
    /// (ARCHITECTURE.md, "The effect seam").
    @ObservationIgnored let effects = EffectRegistry()

    /// The host's Keychain-backed secret store: the stream key lives only
    /// here, never in the project document, an event, or a log. Filed in the
    /// shared keychain access group, so a second Tingra binary can reach the
    /// item (DESTINATIONS.md, "Key sharing between the app and the daemon").
    /// The group is named explicitly because an item written with no group
    /// lands in the first entry of the entitlement's list;
    /// ``DestinationStore`` takes the same group. Internal, so plug-in
    /// secrets (`PlugInSecretStore`) are filed in the same store and group.
    @ObservationIgnored let secureStorage: any SecureStorage = KeychainSecureStorage(
        accessGroup: KeychainSecureStorage.sharedAccessGroup())

    /// The operator's saved destinations (DESTINATIONS.md). Operator-global,
    /// not per-project: the daemon reads the same document so an agent can
    /// resolve "my Twitch" by name. Stream keys stay on ``secureStorage``
    /// (``DestinationStore/secureStorageAccount(for:)``).
    @ObservationIgnored lazy var destinationStore = DestinationStore(eventBus: eventBus)

    /// This project's destination references as loaded, held until the store
    /// read that turns them into panel rows completes: the document arrives
    /// synchronously and the store from an actor.
    @ObservationIgnored var projectDestinationReferences: [DestinationReference]?

    /// The active stream session, or nil when not streaming (v1's one active
    /// session — GLOSSARY.md, "Session").
    @ObservationIgnored var streamSession: StreamSession? {
        didSet { updateKeepAwakeSwitch() }
    }

    /// The task running the active session's `run()`, retained so its outcome
    /// resolves the status and cleans up.
    @ObservationIgnored var streamTask: Task<Void, Never>?

    /// The task reading the active session's live statistics into
    /// ``streamStats`` and ``destinationStats``: one reading a second, kept
    /// newest-only by the session, so nothing queues on the main actor.
    @ObservationIgnored var streamStatisticsTask: Task<Void, Never>?

    /// The program tee: the program drain (``programTask``) and the
    /// program-audio drain (``programAudioTask``) hand every frame and mixed
    /// block here for the attached stream and recording sessions, so the
    /// compositor keeps one consumer. Lock-guarded and nonisolated, so the
    /// drains run off the main actor (ARCHITECTURE.md, "Bounded frame streams").
    @ObservationIgnored let tee = ProgramTee()

    /// The task observing the bus for `stream.*` status events — the stream
    /// status is event-driven, never polled.
    @ObservationIgnored private var streamStatusTask: Task<Void, Never>?

    /// The active recording session, or nil when not recording: a second
    /// `StreamSession` with no destinations, so the recording and the stream
    /// start and stop independently (ARCHITECTURE.md, "Recording in the
    /// app"). It puts nothing on air, so v1's one-active-session rule holds.
    @ObservationIgnored var recordSession: StreamSession? {
        didSet { updateKeepAwakeSwitch() }
    }

    /// The task running the recording session's `run()`.
    @ObservationIgnored var recordTask: Task<Void, Never>?

    /// Where the operator's recording folder and container live.
    @ObservationIgnored let recordingPreferences: RecordingPreferences

    /// Where the stream's compression choices persist.
    @ObservationIgnored let streamingPreferences: StreamingPreferences

    /// Where the operator's snapshots folder lives.
    @ObservationIgnored let snapshotPreferences: SnapshotPreferences

    /// Where the operator's Keep Mac Awake choice lives.
    @ObservationIgnored private let keepAwakePreferences: KeepAwakePreferences

    /// Holds the Mac awake while a stream or a recording runs and
    /// ``keepsMacAwake`` is on. The app's sessions are handed no keep-awake
    /// of their own; this owns the one hold for both.
    @ObservationIgnored private let keepAwakeSwitch: KeepAwakeSwitch

    /// The on-disk marker of the stream this run has on air, written when it
    /// goes live and removed when it stops or at a clean quit
    /// (ARCHITECTURE.md, "Offering to resume a stream after the app dies").
    @ObservationIgnored let liveStreamRecord: LiveStreamRecord

    /// Whether the Mac is being held awake right now.
    var isHoldingMacAwake: Bool { keepAwakeSwitch.isHolding }

    /// Tells the switch whether a session is running, from the two session
    /// references — set when a session starts and cleared only after its
    /// run has returned, so the hold covers a recording being finalized.
    private func updateKeepAwakeSwitch() {
        keepAwakeSwitch.isSessionRunning = streamSession != nil || recordSession != nil
    }

    /// Renders and writes snapshots, off the main actor (``SnapshotWriter``).
    @ObservationIgnored let snapshotWriter = SnapshotWriter()

    /// The pending dismissal of ``snapshotFeedback``'s badge, if one is up.
    @ObservationIgnored var snapshotFeedbackTask: Task<Void, Never>?

    /// The program geometry and rate, a project setting (ARCHITECTURE.md,
    /// "The program format as a project setting"): 1080p30 until the project
    /// loads its own, changed by ``setProgramFormat(_:)``.
    var format = ProgramFormat()

    /// The program geometry, for the layer inspector's pixel fields
    /// (``LayerInspectorUnit``).
    var programFormat: ProgramFormat {
        format
    }

    /// Changes the program's size and frame rate, live at the next tick
    /// (``Compositor/setFormat(_:)``), and saves it with the project.
    /// Refused with a `program.format` error event while streaming or
    /// recording, when the sinks' compression sessions are open at a size.
    ///
    /// - Parameter newFormat: The program's new size and frame rate.
    func setProgramFormat(_ newFormat: ProgramFormat) {
        if let reason = ProgramFormatChoice.refusal(isStreaming: isStreaming, isRecording: isRecording) {
            eventBus.error(
                "program.format",
                domain: .composition,
                params: [
                    "resolution": .string("\(newFormat.width)x\(newFormat.height)"),
                    "fps": .int(newFormat.frameRate),
                    "reason": .string(reason),
                ]
            )
            return
        }
        guard newFormat != format else { return }
        format = newFormat
        compositor.setFormat(newFormat)
        scheduleAutosave()
    }

    /// Whether the project's presets exist yet — loaded from the project file
    /// in ``start(launch:)``, or seeded from ``ProgramLayout`` on the first
    /// configuration pass. Nothing saves before they do.
    var hasSessionPreset: Bool { !presets.isEmpty }

    /// The store of the **default project**: what a fresh install opens, a
    /// launch falls back to, and the Data settings pane removes
    /// (ARCHITECTURE.md, "Projects as documents").
    @ObservationIgnored let defaultStore = ProjectStore()

    /// The store of the **open project** — the default one until the
    /// operator opens, creates, or saves as another through the File menu —
    /// which the document loads from and autosaves to.
    @ObservationIgnored var store = ProjectStore()

    /// The open project's file, observed so the window's title and document
    /// proxy follow a switch (``TingraApp``).
    var projectURL: URL

    /// The open project's name — its file name without the extension — for
    /// the window title.
    var projectName: String {
        projectURL.deletingPathExtension().lastPathComponent
    }

    /// The open project's identity: read from the document, or assigned to
    /// a document written before projects had ids and saved with it. What
    /// the session position is scoped by (``SessionPreferences``).
    @ObservationIgnored var projectID: ProjectID?

    /// The project-scoped storage of app-tier plug-ins, by plug-in id, held
    /// opaque and written back as read so a project opened without a plug-in
    /// keeps its data (PLUGINS.md, Decision 7; ``plugInProjectData(for:)``).
    @ObservationIgnored var plugInData: [String: JSONValue] = [:]

    /// The host's monitor overlay registry, which overlay plug-ins register
    /// into through the plug-in context (PLUGINS.md, Decision 53). Read once,
    /// after activation, into ``monitorOverlayCatalog``.
    @ObservationIgnored private let monitorOverlayRegistry = MonitorOverlayRegistry()

    /// Every registered monitor overlay, in the order the Overlays submenus
    /// list them: the main-actor snapshot a menu and a draw read
    /// (``fillMonitorOverlayCatalog(with:)``).
    var monitorOverlayCatalog = MonitorOverlayCatalog.empty

    /// The open project's monitor overlays, or `nil` when the operator has
    /// never changed them, which reads as ``defaultMonitorOverlays`` and
    /// saves as an absent key (PLUGINS.md, Decision 55).
    var monitorOverlaySettings: MonitorOverlaySettings?

    /// The host's tool registry: what the MCP endpoint lists and dispatches
    /// against, and what host-tier plug-ins and the first-party program
    /// tools register into (PLUGINS.md, Decision 10).
    @ObservationIgnored let toolRegistry = ToolRegistry()

    /// The host's resource registry: what the MCP endpoint lists, reads, and
    /// subscribes plug-ins to, rendered from this model's state
    /// (`EngineResources`; PLUGINS.md, Phase 2). Filled once the engine is up.
    @ObservationIgnored let resourceRegistry = ResourceRegistry()

    /// The projects opened, created, or saved as through the File menu, most
    /// recent first, for the Open Recent submenu. Kept by the system's
    /// document controller and mirrored here so the menu observes a change.
    var recentProjectURLs: [URL] = []

    /// A project the Finder asked the app to open while the engine was still
    /// booting — a double-clicked document — opened once ``start(launch:)`` has
    /// the show up (``openProjectWhenReady(_:)``).
    @ObservationIgnored var pendingProjectURL: URL?

    /// Where the operator's position — active preset, program shot, staged
    /// shot — persists between launches (``SessionPreferences``), scoped to
    /// the open project once its id is known.
    @ObservationIgnored var sessionPreferences = SessionPreferences()

    /// The position recorded by the last run, read by ``loadProject()`` and
    /// consumed once by ``establishSessionPreset()``. While it is set,
    /// nothing records the position (``recordSessionPosition()``).
    @ObservationIgnored var restoredPosition: SessionPosition?

    /// The pending debounced autosave, if any — each edit restarts the delay
    /// so a slider drag coalesces into one write (see ``scheduleAutosave()``).
    @ObservationIgnored var autosaveTask: Task<Void, Never>?

    /// Whether ``removeAllData()`` has run: from then on nothing autosaves,
    /// so the document the operator just removed is not written back by the
    /// next edit or by the quit that follows (``saveProject()``).
    @ObservationIgnored var isRemovingData = false

    /// What the app has saved on this Mac, and the way to remove all of it:
    /// the Data settings pane's model, over the same stores this engine
    /// writes through (``AppDataStore``). The preferences domain is the
    /// bundle identifier, or the process name, as the standard defaults use.
    @ObservationIgnored private(set) lazy var appData = AppDataModel(
        store: AppDataStore(
            projectStore: defaultStore,
            destinationsFileURL: destinationStore.fileURL,
            streamHistoryStore: streamHistoryStore,
            logSessionFileURL: LogSession.counterFileURL,
            logFileURL: logFile.url,
            defaults: .standard,
            defaultsDomain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
            secureStorage: secureStorage,
            plugInDirectory: PlugInApplicationStore.defaultDirectory,
            plugInStateDirectory: PlugInBundleLoader.standardStateDirectory,
            recordingFolder: { [recordingPreferences] in recordingPreferences.folder },
            snapshotFolder: { [snapshotPreferences] in snapshotPreferences.folder }
        ),
        eventBus: eventBus
    )

    /// The log file's size and its two actions — the Logging settings pane's
    /// model and the Help menu's Share Log File… — over the same ``logFile``
    /// the file sink appends to (``LogFileModel``).
    @ObservationIgnored private(set) lazy var logFileModel = LogFileModel(logFile: logFile, eventBus: eventBus)

    /// The stream history: every streamed session and the figures over all
    /// of them, kept in ``streamHistoryStore`` (``StreamHistoryModel``).
    /// Lazy, so a launch that neither streams nor opens the pane reads none.
    @ObservationIgnored private(set) lazy var streamHistory = StreamHistoryModel(
        store: streamHistoryStore, eventBus: eventBus)

    /// Where the stream history persists: beside the default project in the
    /// app, a temporary folder in tests. Injected so a test's
    /// `stream.started` never writes into the operator's own history.
    @ObservationIgnored private let streamHistoryStore: StreamHistoryStore

    /// Which installed plug-ins are turned off: the Plug-ins settings pane's
    /// model, over the same `plug-ins.json` the bundle loader reads at every
    /// launch (``PlugInEnablementModel``, PLUGINS.md, Decisions 34 and 36).
    @ObservationIgnored private(set) lazy var plugInEnablement = PlugInEnablementModel(
        store: PlugInEnablementStore(), eventBus: eventBus)

    /// The Log window's model — the log file's recent lines, followed live
    /// while the window is open — over the same ``logFile`` the file sink
    /// appends to (``LogWindowModel``).
    @ObservationIgnored private(set) lazy var logWindowModel = LogWindowModel(logFile: logFile, eventBus: eventBus)

    /// The video effect providers the renderer resolves layer chains
    /// against — filled at boot from the effect registry, before the
    /// compositor starts.
    @ObservationIgnored let videoEffectProviders = VideoEffectProviderBox()

    /// A renderer for the shot bank's thumbnails, resolving layer chains
    /// through the same ``videoEffectProviders`` as the compositor's, so a
    /// tile composes a shot as program would (ARCHITECTURE.md, "Shot
    /// thumbnails are the shot"). Its effect instances are its own.
    ///
    /// - Parameter context: The context the thumbnails will be drawn with.
    /// - Returns: The renderer.
    func makeThumbnailRenderer(context: CIContext) -> CoreImageShotRenderer {
        CoreImageShotRenderer(context: context) { [videoEffectProviders] configuration in
            videoEffectProviders.provider(for: configuration.effect)?
                .makeEffect(parameters: configuration.parameters)
        }
    }

    /// The compositor producing the program frames. Its renderer resolves
    /// layer chains through ``videoEffectProviders``, so `TingraComposition`
    /// needs no effect registry (ARCHITECTURE.md, "Per-layer video effects").
    @ObservationIgnored lazy var compositor = Compositor(
        clock: clock,
        format: format,
        eventBus: eventBus,
        makeRenderer: { [videoEffectProviders] in
            CoreImageShotRenderer { configuration in
                videoEffectProviders.provider(for: configuration.effect)?
                    .makeEffect(parameters: configuration.parameters)
            }
        }
    )

    /// The mixer producing the program audio — every unmuted strip's device
    /// combined into the program mix on the same master clock that paces the
    /// compositor (GLOSSARY.md, "Mixer"; ARCHITECTURE.md, "The audio mixer").
    @ObservationIgnored lazy var mixer = AudioMixer(clock: clock, eventBus: eventBus)

    /// The monitor: the engine's audio output path, playing the program mix
    /// to the operator's chosen device (GLOSSARY.md, "Monitor"). A sink,
    /// never a second bus (ARCHITECTURE.md, "The monitor path").
    @ObservationIgnored let monitor: any AudioMonitor

    /// Where the monitor's device and level persist: machine-local
    /// preferences, since a project carried to another Mac would name a
    /// device that does not exist there.
    @ObservationIgnored let monitorPreferences: MonitorPreferences

    /// The task draining the monitor's device-list updates, so a device
    /// connected or disconnected reaches the picker as an event rather than
    /// a poll.
    @ObservationIgnored var monitorDeviceTask: Task<Void, Never>?

    /// The log sinks' drain tasks — console, OSLog, and file — retained so
    /// each keeps consuming the bus for the app's lifetime, and awaited at
    /// shutdown so the last events reach every one (``shutDown(reason:)``).
    @ObservationIgnored private var logSinkTasks: [Task<Void, Never>] = []

    /// The inputs currently started, keyed by id, so selection changes start
    /// and stop only what actually changed.
    @ObservationIgnored var activeInputs: [InputID: any Input] = [:]

    /// The audio inputs currently started for the mixer's unmuted strips,
    /// keyed by id — muting a strip stops its device (the microphone
    /// indicator goes dark), unmuting starts it again.
    @ObservationIgnored var activeAudioInputs: [InputID: any Input] = [:]

    /// Which pass needs each input running (``InputClaims``), so an input
    /// both a layer and a strip need is started by the first and stopped
    /// only by the last. These claims alone decide `start()` and `stop()`.
    @ObservationIgnored var inputClaims = InputClaims()

    /// The task draining the compositor's program stream into the relay.
    @ObservationIgnored private var programTask: Task<Void, Never>?

    /// The task draining the compositor's preview frames into the preview
    /// relay. It tees nowhere: nothing on preview reaches a stream or
    /// recording sink (GLOSSARY.md, "Preview").
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// The task draining the mixer's program-audio stream, handing each
    /// mixed block to the tee and the monitor.
    @ObservationIgnored private var programAudioTask: Task<Void, Never>?

    /// The task draining the mixer's meter stream into ``meterRelay`` — one
    /// reading per mix tick, display data only, never the event bus
    /// (EVENTS.md, control plane only).
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    /// The pending one-shot tally refresh for a transition in flight, if
    /// any (see ``scheduleTallyRefresh(after:)``).
    @ObservationIgnored var tallyRefreshTask: Task<Void, Never>?

    /// Whether ``start(launch:)`` has run, so it boots the engine once.
    @ObservationIgnored var started = false

    /// Why this launch is in safe mode, which loads no plug-in bundles, or
    /// `nil` for a normal launch (PLUGINS.md, Decision 31). Set once, as the
    /// engine boots.
    private(set) var safeModeTrigger: PlugInSafeModeTrigger?

    /// Every host-tier plug-in this launch met, compiled-in and bundled, or
    /// `nil` until the engine has booted: the report `tingra-cli plug-ins`
    /// prints (PLUGINS.md, Decisions 35 and 36). Set once per launch.
    private(set) var plugInReport: PlugInLoadReport?

    /// Whether any ``applyConfiguration()`` pass has completed: the first
    /// pass establishes the session preset, seeding a fresh project, and
    /// later passes only sync inputs.
    @ObservationIgnored var hasAppliedConfiguration = false

    /// Inputs whose last start attempt ended
    /// ``CaptureInputError/startedSilent(_:within:)``: started without error
    /// but delivering nothing. A pass skips these rather than pay the
    /// verification window again; a device connecting, a permission grant,
    /// or the operator asking for the input clears the set.
    @ObservationIgnored var silentInputs: Set<InputID> = []

    /// Whether a ``reconfigure()`` pass is currently running. `reconfigure()`
    /// suspends at `input.start()`/`stop()`, so without this guard requests
    /// arriving together would interleave and race the input start/stop.
    @ObservationIgnored var reconfiguring = false

    /// Set whenever a reconfigure is requested while one is already running,
    /// so the running pass loops once more and applies the latest state —
    /// coalescing a burst of requests into the minimum number of passes.
    @ObservationIgnored var reconfigureRequested = false

    /// Whether a ``reconfigureAudio()`` pass is currently running — the audio
    /// mirror of ``reconfiguring``, guarding the strip devices' start/stop.
    @ObservationIgnored var reconfiguringAudio = false

    /// Set whenever an audio reconfigure is requested while one is already
    /// running (see ``reconfigureRequested``).
    @ObservationIgnored var audioReconfigureRequested = false

    /// Creates the model. The engine boots in ``start(launch:)`` when the
    /// window appears, not here. Every default is the real implementation;
    /// tests pass doubles and throwaway stores.
    ///
    /// - Parameters:
    ///   - monitor: The audio output path the operator monitors through.
    ///   - monitorPreferences: Where the monitor device and level persist.
    ///   - authorization: Where the system permissions are read from.
    ///   - snapshotPreferences: Where the snapshots folder persists.
    ///   - recordingPreferences: Where the recording choices persist.
    ///   - streamingPreferences: Where the stream's compression choices persist.
    ///   - keepAwakePreferences: Where the Keep Mac Awake choice persists.
    ///   - keepAwake: What holds the Mac awake while a session runs.
    ///   - liveStreamRecord: The marker of the stream on air.
    ///   - streamHistoryStore: Where the stream history persists.
    ///   - defaultMicrophoneID: Reads the system default microphone's input id.
    init(
        monitor: any AudioMonitor = AVAudioEngineMonitor(),
        monitorPreferences: MonitorPreferences = MonitorPreferences(),
        authorization: any AuthorizationChecking = SystemAuthorization(),
        snapshotPreferences: SnapshotPreferences = SnapshotPreferences(),
        recordingPreferences: RecordingPreferences = RecordingPreferences(),
        streamingPreferences: StreamingPreferences = StreamingPreferences(),
        keepAwakePreferences: KeepAwakePreferences = KeepAwakePreferences(),
        keepAwake: any KeepAwake = ProcessActivityKeepAwake(),
        liveStreamRecord: LiveStreamRecord = LiveStreamRecord(),
        streamHistoryStore: StreamHistoryStore = StreamHistoryStore(directory: ProjectStore().directoryURL),
        defaultMicrophoneID: @escaping @Sendable () -> InputID? = { SystemDefaultInputs.microphoneID }
    ) {
        self.monitor = monitor
        self.defaultMicrophoneID = defaultMicrophoneID
        self.liveStreamRecord = liveStreamRecord
        self.streamHistoryStore = streamHistoryStore
        self.projectURL = ProjectStore().fileURL
        self.snapshotPreferences = snapshotPreferences
        self.recordingPreferences = recordingPreferences
        self.monitorPreferences = monitorPreferences
        self.authorization = authorization
        self.monitorDeviceUID = monitorPreferences.deviceUID
        self.monitorDeviceName = monitorPreferences.deviceName
        self.monitorLevel = monitorPreferences.level
        self.isMonitorMuted = monitorPreferences.isMuted
        self.recordingFolder = recordingPreferences.folder
        self.recordingContainer = recordingPreferences.container
        self.recordingVideoCodec = recordingPreferences.videoCodec
        self.recordingAudioBitsPerSecond = recordingPreferences.audioBitsPerSecond
        self.streamingPreferences = streamingPreferences
        self.streamAudioBitsPerSecond = streamingPreferences.audioBitsPerSecond
        self.snapshotFolder = snapshotPreferences.folder
        self.keepAwakePreferences = keepAwakePreferences
        self.keepsMacAwake = keepAwakePreferences.isEnabled
        self.keepAwakeSwitch = KeepAwakeSwitch(
            keepAwake: keepAwake, eventBus: eventBus, isEnabled: keepAwakePreferences.isEnabled)
        let meterRelay = MeterRelay()
        self.meterRelay = meterRelay
        self.meterDisplayLink = MeterDisplayLink(relay: meterRelay)
    }

    /// Boots the engine: attaches the log sinks and records the launch,
    /// activates the capture and generator plug-ins, discovers inputs, starts
    /// the compositor, and begins feeding the preview. Idempotent.
    ///
    /// - Parameter launch: Whether this launch is in safe mode, and the
    ///   operator's answer to the offer made after an unclean exit
    ///   (PLUGINS.md, Decisions 31 and 32).
    func start(launch: SafeModeLaunch = .normal) async {
        guard !started else { return }
        started = true
        safeModeTrigger = launch.trigger

        // The log sinks, attached before the first event so none is missed
        // (EVENTS.md, "Sinks"): the log file always, then stdout or OSLog,
        // never both, since Xcode's console would print every event twice.
        logSinkTasks = [eventBus.attach(FileSink(url: logFile.url))]
        if LaunchEnvironment.logsToConsole {
            logSinkTasks.append(eventBus.attach(ConsoleEventSink()))
        } else {
            logSinkTasks.append(eventBus.attach(OSLogSink()))
        }
        // The first line of every log names the build it came from, so a
        // shared log can be matched to its report (``LaunchDiagnostics``).
        eventBus.app(LaunchDiagnostics.eventName, domain: .platform, params: LaunchDiagnostics().params)
        // The safe-mode offer's click happened before there was anywhere to
        // record it, so it goes on the bus now, ahead of its effect.
        launch.reportOfferTap(on: eventBus)
        // One bus consumer, attached before the plug-ins activate so neither
        // a `stream.*` status change nor the first `device.*` event can be
        // missed (event-driven, never polled).
        let busEvents = eventBus.events()
        streamStatusTask = Task { [weak self] in
            for await event in busEvents {
                self?.handleStreamStatusEvent(event)
                await self?.handleDeviceEvent(event)
                await self?.handleInputRuntimeError(event)
                self?.handleApplicationAudioArrived(event)
            }
        }
        // The permissions picture goes on the bus before any input asks for
        // one. Each app activation re-reads it (never a poll), and a grant
        // made in System Settings starts the inputs it unblocks.
        permissions.refresh()
        permissions.observeActivation { [weak self] granted in
            await self?.applyNewlyGranted(granted)
        }
        let context = PlugInContext(
            eventBus: eventBus,
            clock: clock,
            inputs: registry,
            outputs: outputs,
            effects: effects,
            tools: toolRegistry,
            media: mediaRegistry,
            monitorOverlays: monitorOverlayRegistry
        )
        let activation = await PlugInLoader().activate(
            [
                AVFoundationCapturePlugIn(), ScreenCaptureKitCapturePlugIn(), GeneratorPlugIn(),
                HaishinKitOutputPlugIn(), EffectPlugIn(), RecordingPlugIn(), MediaPlugIn(), MonitorPlugIn(),
                ProgramToolsPlugIn(program: self, outputs: self), MonitorOverlayToolsPlugIn(overlays: self),
            ],
            thenBundlesFrom: PlugInBundleLoader(frontEnd: "Tingra", safeMode: launch.trigger),
            in: context
        )
        // Once bundles have loaded, a run that ends without terminating is
        // one the next launch offers safe mode after (PLUGINS.md, Decision
        // 32); ``TingraAppDelegate`` removes the record at a clean quit.
        plugInReport = activation.report
        let loadedBundles = activation.scan.loaded.map(\.url.lastPathComponent)
        if !loadedBundles.isEmpty {
            PlugInLaunchRecord().write(bundles: loadedBundles)
        }
        for resource in EngineResources.all(for: self) {
            do {
                try await resourceRegistry.register(resource)
            } catch {
                eventBus.error(
                    "resource.registration", domain: .control,
                    params: ["uri": .string(resource.uri), "error": .string(String(describing: error))])
            }
        }
        mediaContentTypes = await mediaRegistry.acceptedContentTypes
        // The recordings folder's free space is read now and again whenever
        // something can have changed the answer, never on a timer.
        refreshRecordingCapacity()
        audioEffectChoices = await effects.allAudioProviders.map {
            AudioEffectChoice(id: $0.id, name: $0.name, parameters: $0.parameters)
        }
        let videoProviders = await effects.allVideoProviders
        videoEffectChoices = videoProviders.map {
            VideoEffectChoice(id: $0.id, name: $0.name, parameters: $0.parameters)
        }
        // The renderer resolves layer chains against this snapshot; it is
        // filled before the compositor starts below.
        videoEffectProviders.fill(with: videoProviders)
        destinationTemplates = await outputs.destinationTemplates
        fillMonitorOverlayCatalog(with: await monitorOverlayRegistry.allProviders)

        await readDeviceLists()
        loadProject()
        // The device lists were built before the document was read, so the
        // inputs it tunes are handed their stored settings now.
        await applyStoredInputParameters()
        // The project's media registers after the document is read and
        // before the lists are used: each item becomes an input.
        if !media.isEmpty {
            await registerProjectMedia()
            await readDeviceLists()
        }
        // The project's windows register the same way, for the same reason.
        if !windows.isEmpty {
            await registerProjectWindows()
            await readDeviceLists()
        }
        // And its applications.
        if !applications.isEmpty {
            await registerProjectApplications()
            await readDeviceLists()
        }
        await loadDestinations()
        // The strips are the loaded preset's authored audio channels, named
        // from discovery. When the document authored none, the seed policy
        // applies: one unmuted strip on the system default microphone.
        mixerStrips = MixerStrip.strips(
            channels: presets.first { $0.id == activePresetID }?.audioChannels,
            discovered: audioInputs,
            preferring: defaultMicrophoneID()
        )

        let program = compositor.programFrames()
        // The preview consumer is attached from boot; the compositor renders
        // the second pass only once a shot is actually staged, so an idle
        // preview costs nothing (ARCHITECTURE.md, "The preview bus").
        let preview = compositor.previewFrames()
        compositor.start()
        // Both drains run off the main actor (`Task.detached`), so a busy
        // main thread can only cost the monitor a draw, never queue frames
        // (ARCHITECTURE.md, "Bounded frame streams").
        let previewRelay = self.previewRelay
        previewTask = Task.detached {
            for await frame in preview {
                // A frame the tick rendered just before preview was cleared
                // can still be in flight here; the relay stops accepting when
                // preview clears, so it cannot repaint the emptied monitor.
                previewRelay.store(frame)
            }
        }
        let programRelay = self.programRelay
        let tee = self.tee
        let eventBus = self.eventBus
        programTask = Task.detached {
            var sawFrame = false
            for await frame in program {
                programRelay.store(frame)
                // Tee the same frame into the attached stream and recording
                // sessions, so the compositor's single-consumer contract
                // holds (ARCHITECTURE.md, "Recording in the app").
                tee.yield(frame)
                if !sawFrame {
                    sawFrame = true
                    // A one-time milestone, not per-frame traffic: confirms
                    // the compositor is producing program frames at all.
                    eventBus.event("preview.firstFrame", domain: .composition)
                }
            }
        }

        // The program mix runs from boot like the compositor. Its one drain
        // hands each mixed block to the sessions and to the monitor, so
        // neither can alter the mix the other receives.
        let programAudio = mixer.programAudio()
        let monitor = self.monitor
        mixer.start()
        programAudioTask = Task.detached {
            for await block in programAudio {
                tee.yield(block)
                await monitor.play(block)
            }
        }

        // The meters ride the same mix tick: one pre-fader reading per strip
        // and the post-fader master per block, into the relay the meters
        // sample at display cadence. Never the event bus (EVENTS.md).
        let meters = mixer.meterReadings()
        let meterRelay = self.meterRelay
        let meterFeed = self.meterFeed
        meterTask = Task.detached {
            for await block in meters {
                meterRelay.fold(block)
                meterFeed.fold(block)
            }
        }

        await startMonitorDeviceUpdates()

        await reconfigure()
        await reconfigureAudio()

        // A document double-clicked while the engine was booting: the show
        // is up now, so it can be replaced like any File ▸ Open.
        if let url = pendingProjectURL {
            pendingProjectURL = nil
            await openProject(at: url)
        }

        // Last, with the project open and the program running, so the
        // operator can see what would go on air before answering.
        await offerStreamResume()
    }

    // MARK: Layer edits

    /// The pasteboard's change count as of the app's last layer copy, or
    /// nil before one — observed state standing in for the pasteboard,
    /// which cannot be observed (``canPasteLayer(from:)``).
    var layerPasteboardChangeCount: Int?

    // MARK: - Recording

    /// What the recording session calls itself on the two events that name a
    /// session rather than a destination, so the streaming panel can ignore
    /// them (see `StreamSession.label`).
    static let recordSessionLabel = "record"

    // MARK: Snapshots

    /// Turns holding the Mac awake during a stream or a recording on or off
    /// and persists the choice. It takes effect at once, mid-session too.
    ///
    /// - Parameter isEnabled: Whether a session should hold the Mac awake.
    func setKeepsMacAwake(_ isEnabled: Bool) {
        guard isEnabled != keepsMacAwake else { return }
        keepsMacAwake = isEnabled
        keepAwakePreferences.isEnabled = isEnabled
        keepAwakeSwitch.isEnabled = isEnabled
        eventBus.event("keepAwake.settingChanged", domain: .platform, params: ["enabled": .bool(isEnabled)])
    }

    /// The `Int` inside an event value, when it is one.
    static func intValue(_ value: EventValue) -> Int? {
        if case .int(let int) = value { return int }
        return nil
    }

    /// The `String` inside an event value, when it is one.
    static func stringValue(_ value: EventValue) -> String? {
        if case .string(let string) = value { return string }
        return nil
    }

    // MARK: Lifecycle

    /// Records the app's shutdown on the bus and makes sure the record lands
    /// before the process exits. Called from the app delegate for every quit
    /// (``TingraAppDelegate/applicationShouldTerminate(_:)``).
    ///
    /// It emits one `app.terminating` event, writes a pending autosave,
    /// closes the stream history's entry for a stream still on air, and
    /// finalizes the recording, since an unfinalized movie is unplayable. It
    /// then shuts the bus down and awaits every log sink's drain: an event
    /// still buffered at exit was never logged. Nothing else is torn down.
    ///
    /// - Parameter reason: What brought the quit on (``TerminationReason``).
    func shutDown(reason: TerminationReason) async {
        eventBus.app(
            "app.terminating",
            domain: .platform,
            params: [
                "reason": .string(reason.rawValue),
                "recording": .bool(isRecording),
                "streaming": .bool(isStreaming),
            ]
        )
        // Before the bus shuts down, so its `project.saved` (or
        // `project.save` error) reaches the log with the rest of the quit.
        if autosaveTask != nil { saveProject() }
        // A clean quit while live is the operator's choice: nothing to offer
        // at the next launch, even if the stream's stop event arrives late.
        liveStreamRecord.remove()
        // The stream goes with the process and reports no end of its own, so
        // the history's open entry is closed here; otherwise a quit on air
        // would read as a crash at the next launch.
        if isStreaming { recordStreamEnded(reason: .appQuit, at: Date()) }
        await finishRecording()
        eventBus.shutdown()
        for task in logSinkTasks {
            await task.value
        }
        logSinkTasks = []
    }

    // MARK: Monitor overlays

    /// The monitor overlays a project shows before the operator changes
    /// them: the tally border on both bus monitors, and nothing else
    /// (PLUGINS.md, Decision 55).
    static let defaultMonitorOverlays = MonitorOverlaySettings(
        program: [TallyBorderOverlayProvider.overlayID], preview: [TallyBorderOverlayProvider.overlayID])

    /// The monitor overlays in effect: the project's, or the defaults when
    /// it has none.
    var effectiveMonitorOverlays: MonitorOverlaySettings {
        monitorOverlaySettings ?? Self.defaultMonitorOverlays
    }

    /// Removes everything the app has saved on this Mac except recordings,
    /// and stops the engine saving anything further, so the next launch is a
    /// first run (ARCHITECTURE.md, "The Data settings pane").
    ///
    /// The pending autosave is cancelled and later saves refused before the
    /// files go: the engine still holds the show in memory, and an autosave
    /// or the quit's flush would write the document straight back. Saving
    /// stays off even when something could not be removed. The engine keeps
    /// running, so the quit that follows still finalizes a recording.
    ///
    /// - Returns: Whether everything was removed (``AppDataModel/failures``
    ///   names what was not).
    @discardableResult
    func removeAllData() -> Bool {
        isRemovingData = true
        autosaveTask?.cancel()
        autosaveTask = nil
        return appData.removeAll()
    }
}

extension Transition {
    /// The transition's length in seconds — `0` for a cut, which has none.
    /// What a take's audio-follows-video crossfade ramps over, so the sound
    /// moves with the picture.
    var duration: TimeInterval {
        switch self {
        case .cut: 0
        case .dissolve(let seconds), .wipe(_, let seconds), .shader(_, let seconds): seconds
        }
    }

    /// This transition at another length, a cut unchanged: how the panel's
    /// rate knob applies to whatever transition a take resolved to.
    ///
    /// - Parameter duration: The length in seconds.
    /// - Returns: The transition with its duration replaced.
    func withDuration(_ duration: TimeInterval) -> Transition {
        switch self {
        case .cut: .cut
        case .dissolve: .dissolve(duration: duration)
        case .wipe(let edge, _): .wipe(edge: edge, duration: duration)
        case .shader(let name, _): .shader(name: name, duration: duration)
        }
    }
}

/// The transition kinds the shot switcher's picker offers (GLOSSARY.md,
/// "Transition"), mapped to a concrete ``Transition`` with the selected
/// wipe edge or shader and the panel's take duration at take time.
enum TakeTransitionKind: String, CaseIterable {
    /// The taken shot's own ``Shot/defaultTransition`` (a cut when it has
    /// none) — the initial selection, so per-shot defaults are effective
    /// out of the box.
    case `default`

    /// An instant cut, regardless of the taken shot's default.
    case cut

    /// A crossfade over ``EngineModel/takeTransitionDuration``.
    case dissolve

    /// A directional reveal from ``EngineModel/wipeEdge`` over
    /// ``EngineModel/takeTransitionDuration``.
    case wipe

    /// A custom-shader reveal with ``EngineModel/shaderName`` over
    /// ``EngineModel/takeTransitionDuration``.
    case shader
}

/// The video effect providers the compositor's renderer resolves layer
/// chains against, filled once on the main actor at boot, before the
/// compositor starts, and read by the compositor's tick task.
///
/// A reference box because the renderer factory is `@Sendable` and cannot
/// capture a non-copyable `Mutex`. `nonisolated` because the module defaults
/// to main-actor isolation and the tick task reads it off the main actor.
nonisolated final class VideoEffectProviderBox: Sendable {
    /// The providers, keyed by effect id.
    private let providers = Mutex<[EffectID: any VideoEffectProvider]>([:])

    /// Creates an empty box.
    init() {}

    /// Stores the registry's video providers, keyed by id.
    ///
    /// - Parameter registered: The registered video effect providers.
    func fill(with registered: [any VideoEffectProvider]) {
        providers.withLock { providers in
            for provider in registered {
                providers[provider.id] = provider
            }
        }
    }

    /// The provider for an effect id, or nil when this build has none —
    /// the chain slot then renders as pass-through.
    ///
    /// - Parameter id: The effect's stable identifier.
    func provider(for id: EffectID) -> (any VideoEffectProvider)? {
        providers.withLock { $0[id] }
    }
}

/// The model is the program the first-party program tools act on
/// (`ProgramToolsPlugIn`); the conformance is declared here because the
/// seam refines `Sendable`, which a class must adopt in its own file.
extension EngineModel: ProgramControlling {}

extension EngineModel: MonitorOverlayControlling {}

/// The model is also the stream and the recording the program's output
/// tools act on (`ProgramStreamStartTool` and its three siblings), declared
/// here for the same reason.
extension EngineModel: ProgramOutputControlling {}
