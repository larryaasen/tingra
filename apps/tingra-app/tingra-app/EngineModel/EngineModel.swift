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
    /// One selectable input as the pickers and media-role lists show it.
    struct InputChoice: Identifiable, Hashable {
        /// The input's stable identifier.
        let id: InputID

        /// The user-facing name.
        let name: String

        /// The input's provenance. Carried beside the name because a couple
        /// of policies are about *where content comes from* rather than what
        /// the input produces — chiefly the mixer's seed, which must never
        /// put a synthesized tone on air by default (see
        /// ``MixerStrip/seed(from:)``). Deliberately has no default: a
        /// choice carrying the wrong kind would be silent bad data, and
        /// every construction site knows the real one.
        let kind: InputKind
    }

    /// One registered audio effect as the strip's Add Effect menu offers
    /// it: the provider's identity and declared parameters, snapshotted
    /// from the effect registry at boot so the UI never awaits the actor
    /// per draw.
    struct AudioEffectChoice: Identifiable, Equatable {
        /// The effect's stable identifier.
        let id: EffectID

        /// The user-facing effect name, as the provider declares it
        /// (runtime data, shown verbatim like a device name).
        let name: String

        /// The parameters the effect declares, in display order — what
        /// the chain editor draws sliders from.
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

        /// Stop was clicked and the session is ending: flushing compression
        /// and closing each destination's connection, which takes a few
        /// seconds. Set by the app at the request — the session reports
        /// nothing until `stream.stopped`, which settles it — so the
        /// operator sees the click land at once (2026-09-26). Only the
        /// stream's end moves the status on from here; a late `started` or
        /// `reconnected` from a leg still closing does not.
        case stopping

        /// The stream stopped cleanly (Stop, or an elapsed duration).
        case stopped

        /// The stream ended on a failure — a start-time rejection (bad key,
        /// unreachable host) or a connection lost past the reconnect budget.
        /// Carries a developer-facing message (never a secret).
        case error(String)

        /// Whether a session is in flight — starting, live, reconnecting, or
        /// **stopping**. A stopping stream still counts: its session holds
        /// the destinations and the program format until it has closed, so
        /// the fields stay locked and a second start is refused until then.
        var isActive: Bool {
            switch self {
            case .starting, .live, .reconnecting, .stopping: true
            case .idle, .stopped, .error: false
            }
        }
    }

    /// The live state of the app's local recording, derived from the
    /// `recording.*` events its own session emits on the bus.
    ///
    /// Deliberately separate from ``StreamStatus``: recording runs in its own
    /// session, so it starts and stops independently of the stream
    /// (ARCHITECTURE.md, "Recording in the app"). Ending a stream leaves a
    /// recording rolling, and vice versa.
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

    /// A snapshot of the live stream's delivery counters, from a reading of
    /// the session's live statistics — what the panel shows beside the Live
    /// label.
    struct StreamStats: Equatable {
        /// The current send bitrate in kilobits per second.
        let bitrateKbps: Int

        /// The current delivered frame rate.
        let fps: Int
    }

    /// How often the app's stream writes `stream.stats` to the log, in
    /// seconds — each line the average of the minute it covers, the first ten
    /// seconds after going live (the session's default first window, once
    /// delivery has settled). The panel reads the session's once-a-second
    /// live statistics instead, so this sets the log's cadence alone
    /// (EVENTS.md, "Stream statistics: the readout and the log").
    static let streamStatsLogIntervalSeconds = 60

    /// One destination leg's live state, derived from its own share of the
    /// session's per-leg status events — what each row of the streaming panel
    /// shows while the program is on air (ARCHITECTURE.md, "Multiple
    /// destinations").
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
    /// channel strips. Filtered on ``Input/media``, not on ``InputKind``:
    /// the question "can this be a channel strip" is a media question, so an
    /// audio generator belongs here beside the microphones (see
    /// ARCHITECTURE.md, "The `Input` media capability").
    var audioInputs: [InputChoice] = []

    /// Every discovered input that produces **video**, for the layer-tree
    /// editor's add-layer choices. Filtered on ``Input/media`` for the same
    /// reason as ``audioInputs`` — which is what admits the video
    /// generators the editor had to exclude while `InputKind` was the only
    /// thing to filter on.
    var videoInputs: [InputChoice] = []

    /// Every input's name as discovery last reported it, keyed by id — so a
    /// picker can label a selection whose device has gone away.
    ///
    /// A camera that is unplugged **stays selected**, dormant, the way a
    /// layer bound to an undiscovered input and a strip whose device is absent
    /// both do. A SwiftUI `Picker` whose selection matches no tag is undefined
    /// behaviour, though, so keeping the selection requires being able to draw
    /// it — which is what this name is for (see ``inputName(for:)``).
    var lastKnownInputNames: [InputID: String] = [:]

    /// The parameters each registered input declares, keyed by id, for the
    /// inputs that declare any (PLUGINS.md, Decision 15) — snapshotted from
    /// the registry with every device-list rebuild, so a strip's Input
    /// Settings button knows to appear without awaiting the actor per draw.
    /// An input that declares nothing has no entry and gets no button.
    var declaredInputParameters: [InputID: [Parameter]] = [:]

    /// The inputs' parameter values, by input id — the document's
    /// `inputParameters` key (`Project.inputParameters`), applied to each
    /// input through `Input.setParameters` when the project loads and
    /// whenever the input registers, and edited by an input's settings
    /// popover (``setInputParameter(_:forKey:ofInput:)``). An entry for an
    /// input this Mac does not have is kept and written back untouched.
    var inputParameters: [InputID: [String: JSONValue]] = [:]

    /// The values a device keeps for itself, by input id, for the inputs
    /// the open project stores nothing for — a UVC camera's brightness and
    /// white balance as it holds them in firmware (`Input.currentParameters`,
    /// docs/UVC.md). What the settings popover shows, and starts its edits
    /// from, until the operator changes one and the project stores it. Never
    /// written to the document.
    var deviceInputParameters: [InputID: [String: JSONValue]] = [:]

    /// The last application of an edited input payload, chained so edits
    /// made at gesture rate reach the input in the order they were made —
    /// two tasks racing to the registry could otherwise leave a stale
    /// value applied last.
    @ObservationIgnored var inputParameterApplyTask: Task<Void, Never>?

    /// The mixer's channel strips — the level, pan, and mute the mixer panel
    /// edits (GLOSSARY.md, "Channel strip"): the active preset's authored
    /// audio channels merged with live discovery (see
    /// ``MixerStrip/strips(channels:discovered:)``). Strip edits sync back
    /// into the active preset and autosave like shot edits, so the mix
    /// reopens as it was; a strip whose device is absent stays on the panel,
    /// dormant, until the device returns (ARCHITECTURE.md, "Per-strip
    /// routing").
    var mixerStrips: [MixerStrip] = []

    /// The registered audio effects the strips' Add Effect menus offer,
    /// in the registry's stable listing order — snapshotted at boot
    /// (ARCHITECTURE.md, "Audio effect chains").
    private(set) var audioEffectChoices: [AudioEffectChoice] = []

    /// The audio output devices the monitor picker offers, refreshed from
    /// the monitor's device-update stream as devices come and go — never
    /// polled.
    var monitorDevices: [AudioMonitorDevice] = []

    /// The device the operator monitors through, or nil for no monitoring —
    /// the master strip's picker. Nil on a fresh install: monitoring the
    /// program mix through speakers beside a live microphone is a feedback
    /// howl, so it is opt-in (ARCHITECTURE.md, "The monitor path").
    var monitorDeviceUID: String?

    /// The selected device's name as discovery last reported it, or nil when
    /// nothing is selected — the label the master strip's picker shows for a
    /// selection ``monitorDevices`` cannot currently resolve.
    ///
    /// That happens in two situations, and the picker must be able to render
    /// both: for a moment at launch, before the first device list arrives
    /// (the list fills asynchronously, while ``monitorDeviceUID`` is restored
    /// synchronously from preferences), and for as long as a chosen device is
    /// unplugged — which the app deliberately keeps selected so it resumes on
    /// its return.
    var monitorDeviceName: String?

    /// The monitor level — the operator's own listening volume. It scales
    /// only what the monitor plays and never the program mix, so moving it
    /// cannot change what viewers hear.
    var monitorLevel: Double = MonitorPreferences.defaultLevel

    /// Whether the monitor is muted — the control room cut. The device stays
    /// selected and ``monitorLevel`` stays where it was; only what the
    /// monitor plays goes silent, so the program mix, the stream, and the
    /// recording are as untouched by it as by the level.
    var isMonitorMuted = false

    /// Whether the master is muted — the program's sound off air while its
    /// picture keeps going (GLOSSARY.md, "Master mute"). Unlike the monitor
    /// mute it silences everything leaving the mixer: the stream, the
    /// recording, and the monitor with them.
    ///
    /// Session state, deliberately, like ``isFadedToBlack``: it never enters
    /// preferences or the project document, so a show never reopens with no
    /// sound. A forgotten monitor mute fails safe — the operator hears
    /// nothing and notices — but a forgotten master mute is a silent
    /// recording nobody hears happening.
    var isMasterMuted = false

    /// Whether the monitor is currently playing. A selected device that is
    /// not connected leaves this false while keeping the selection, so the
    /// master strip can show the difference between "not monitoring" and
    /// "monitoring through a device that has gone away".
    var isMonitoring = false

    /// The registered video effects the layer editor's Add Effect menu
    /// offers, in the registry's stable listing order — the video mirror
    /// of ``audioEffectChoices`` (ARCHITECTURE.md, "Per-layer video
    /// effects").
    private(set) var videoEffectChoices: [VideoEffectChoice] = []

    /// The destinations the streaming panel edits, persisted in the project
    /// document (the stream keys are not — they live in secure storage, filed
    /// by destination id; see ARCHITECTURE.md, "Streaming the program" and
    /// "Multiple destinations"). Empty until the operator adds one.
    ///
    /// Going live fans the one program out to every enabled destination with
    /// a usable URL, as one session with one leg each.
    var destinations: [DestinationEdit] = []

    /// The destination templates the registered streaming outputs offer —
    /// the well-known services the Streaming settings pane's Add Destination
    /// menu lists and its URL field suggests — sorted by name and snapshotted
    /// at boot like the effect choices (DESTINATIONS.md, "Destination
    /// templates"). Empty until the engine is up.
    private(set) var destinationTemplates: [DestinationTemplate] = []

    /// Whether at least one destination is ready to stream — what the Start
    /// control enables on.
    var hasStreamableDestination: Bool {
        destinations.contains(where: \.isStreamable)
    }

    /// The live streaming status, driven entirely by the `stream.*` events on
    /// the bus (never a poll) — what the Start/Stop control reflects.
    var streamStatus: StreamStatus = .idle

    /// The latest delivery stats from the session's once-a-second live
    /// statistics while live, or nil when not streaming — the panel shows
    /// them beside the Live label. With several destinations
    /// this is the **first live leg's**, never an average across legs that
    /// describes none of them; each leg's own is in ``destinationStats``.
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

    /// When the current stream went on air — the date of the session's
    /// `stream.started` event — or nil when not streaming. It holds through
    /// a reconnect, which is the same session. The status bar's elapsed time
    /// is drawn from this at display cadence, the way the recording's is
    /// from ``recordingStartedAt``.
    var streamStartedAt: Date?

    /// Each streaming destination's latest delivery stats, keyed by
    /// destination id — what the panel's per-destination rows show. Driven by
    /// the session's once-a-second live statistics; cleared when the stream
    /// ends.
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

    /// When the current recording started on the master clock, or nil when not
    /// recording. The panel's elapsed time is drawn from this at display
    /// cadence rather than pushed per tick — the meters' rule, one surface
    /// over.
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
    /// program's settings, or nil when it cannot be measured — shown beside
    /// the folder so the operator sees the room they have before pressing
    /// Record, from the same reading the pre-flight check refuses on.
    var recordingCapacity: RecordingCapacity?

    /// The recording file being written right now, or nil: set by
    /// `recording.started` and cleared by `recording.stopped`, which the
    /// session emits only once the file is finalized. The Library's
    /// Recordings tab marks this file's row as not yet playable, and
    /// ``trashRecording(at:)`` refuses it (ARCHITECTURE.md, "The Recordings
    /// tab").
    var fileBeingRecorded: URL?

    /// Bumped whenever the recordings folder's contents or the folder itself
    /// change by Tingra's hand — a take starting, a take finalized, a trash,
    /// a folder choice — so the Library's Recordings tab re-reads the listing
    /// on the event rather than watching the folder (the
    /// ``snapshotRevision`` twin).
    var recordingRevision = 0

    /// The folder snapshots are saved into, from machine-local preferences
    /// (ARCHITECTURE.md, "Snapshots").
    var snapshotFolder: URL

    /// Whether a stream or a recording holds the Mac awake for its length,
    /// from machine-local preferences (CLOCK.md, "System sleep and App
    /// Nap"). Live: turning it off mid-session lets the Mac sleep again at
    /// once, and turning it on takes the hold at once (``KeepAwakeSwitch``).
    private(set) var keepsMacAwake: Bool

    /// Bumped whenever the snapshots folder's contents or the folder itself
    /// change by Tingra's hand — a save, a trash, a folder choice — so the
    /// Library's Snapshots tab re-reads the listing on the event rather than
    /// watching the folder.
    var snapshotRevision = 0

    /// The badge the last snapshot request put on its monitor, or nil when
    /// none is showing (``SnapshotFeedback``).
    var snapshotFeedback: SnapshotFeedback?

    /// The compression settings a recording is written with — the program's
    /// own geometry and rate, the same settings the free-space estimate is
    /// computed from, so the room the panel shows and the room the pre-flight
    /// check enforces cannot disagree. The codec and the audio bit rate are
    /// the operator's choices; the video bit rate follows the format and the
    /// codec by one rule (``CompressionChoices``), so HEVC writes a smaller
    /// file rather than the same-size one.
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

    /// The compression settings every leg of the stream is sent with — the
    /// program's own geometry and rate, H.264 (the codec every destination
    /// accepts), and the operator's audio bit rate. The video bit rate
    /// follows the format by one rule — a 4K choice must not be compressed
    /// at 1080p's 4500k (ARCHITECTURE.md, "The program format as a project
    /// setting").
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

    /// Whether Stop Recording was clicked and the file is still being closed
    /// — so the control reads Finishing… and cannot be clicked until the
    /// take is playable and a new one can start.
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

    /// The project's presets, in switcher order — what the preset switcher
    /// lists (ARCHITECTURE.md, "Multiple presets in the UI"). The active
    /// preset's entry is refreshed from the live ``shots`` by
    /// ``syncActivePreset()`` before every save, switch, and duplicate.
    var presets: [Preset] = []

    /// The id of the active preset — the one the shot switcher and the
    /// layer-tree editor operate within, highlighted in the preset switcher.
    /// Session state, like the active shot: at launch the app adopts the
    /// document's first preset, never a persisted "active" field.
    var activePresetID: PresetID? {
        didSet { recordSessionPosition() }
    }

    /// The active preset's name, or nil before a preset is active — what the
    /// window's subtitle shows beneath the project's name (``TingraApp``).
    var activePresetName: String? {
        presets.first { $0.id == activePresetID }?.name
    }

    /// The active preset's shots, in switcher order — what the shot bank
    /// shows (roadmap step 7; ARCHITECTURE.md, "The shot bank"). The live
    /// session copy: edits land here (and in the compositor) first, and the
    /// **authored** ones flow back into ``presets`` on save/switch. A
    /// **transient** shot (``ShotOrigin/automatic``) — made to stage an input
    /// the operator clicked — lives here and in the compositor only while it
    /// is staged, and is never written to the document; see
    /// ``reconcileTransientShots()``.
    var shots: [Shot] = []

    /// The id of the shot currently on program, so the switcher can highlight
    /// it. `nil` when there are no shots (no input selected). Session state
    /// that never enters the project document, remembered machine-locally so
    /// a launch can put it back (``recordSessionPosition()``).
    var activeShotID: ShotID? {
        didSet { recordSessionPosition() }
    }

    /// The id of the shot staged on preview, or `nil` when nothing is staged
    /// — the staging bus's selection, mirrored from the compositor so the
    /// shot bank can light it. Session state: what is staged when the
    /// app quits is not part of the show, so it never enters the project
    /// document (ARCHITECTURE.md, "The preview bus") — but it is remembered
    /// machine-locally, so the next launch stages it again
    /// (``recordSessionPosition()``).
    ///
    /// Clearing it also empties ``previewRelay``: the compositor yields no
    /// preview frame while nothing is staged, so without this the monitor
    /// would keep drawing the last staged frame as if it had frozen. An
    /// empty preview shows nothing (ARCHITECTURE.md, "The preview bus").
    var previewShotID: ShotID? {
        didSet {
            previewRelay.setAccepting(previewShotID != nil)
            recordSessionPosition()
        }
    }

    /// Whether the program is faded to black — picture *and* sound
    /// (GLOSSARY.md, "Fade to black"). The **latch**, so it flips the moment
    /// the operator acts rather than tracking either ramp: the button's state
    /// and the program monitor's badge both read it, and neither should lag a
    /// half-second behind the click.
    ///
    /// Session state, deliberately: it never enters the project document, so
    /// a show never reopens black (ARCHITECTURE.md, "Fade to black").
    var isFadedToBlack = false

    /// The inputs the engine is currently running, in name order — the
    /// multiview's tiles (GLOSSARY.md, "Multiview").
    ///
    /// Exactly what is running, never what is merely discovered: opening a
    /// monitoring window must not start a device, and a camera indicator
    /// lighting up because the operator opened a window would be a defect.
    /// A running input that has not delivered its first frame yet still
    /// gets a tile — a black one carrying its name — so tiles do not pop in.
    var multiviewInputs: [InputChoice] = []

    /// The inputs contributing to what is on program, for the multiview
    /// tiles' **tally** lamps (GLOSSARY.md, "Tally"). Mirrored from
    /// ``Compositor/programInputIDs``, which unions the outgoing shot's
    /// inputs while a transition is in progress.
    var programInputIDs: Set<InputID> = []

    /// The inputs contributing to the shot staged on preview — the green
    /// half of the tally (see ``programInputIDs``). Derived from the
    /// compositor's staged shot; transitions are program-only, so there is
    /// nothing to union here.
    var previewInputIDs: Set<InputID> = []

    /// The shot on program, as the switcher highlights it — `nil` when there
    /// are no shots, or while a preset switch holds a snapshot from outside
    /// the pool (see ``programShot``).
    var activeShot: Shot? {
        shots.first { $0.id == activeShotID }
    }

    /// The shot on program, as the program monitor's caption names it: the
    /// active shot, or — while a preset switch holds the outgoing shot on
    /// program as a snapshot from outside the loaded pool
    /// (``Compositor/loadPreset(_:)``) — the held shot, which no id in
    /// ``shots`` resolves. `nil` when the program is background-only: no
    /// shot at all, or the nameless empty shot a removed preset leaves.
    ///
    /// Read through the compositor for the held case rather than mirrored
    /// into a stored property, because every transition into and out of a
    /// hold already reassigns ``activeShotID``, which this getter reads — so
    /// the caption re-evaluates exactly when the answer can change.
    var programShot: Shot? {
        if let activeShot { return activeShot }
        let rendering = compositor.programShot
        return rendering.name.isEmpty ? nil : rendering
    }

    /// The shot staged on preview, as the preview monitor's caption names it,
    /// or `nil` while nothing is staged. Resolved against ``shots``, which
    /// holds the transient shot ``stagePreview(showing:)`` makes as well as
    /// the authored ones.
    var previewShot: Shot? {
        shots.first { $0.id == previewShotID }
    }

    /// The shot the layer-tree editor follows, with its tally: the shot
    /// staged on preview, or the shot on program when nothing is staged —
    /// ``EditedShot``'s rule over the two bus ids. `nil` when neither bus
    /// carries a shot from ``shots`` (an empty pool, or a held program
    /// snapshot with nothing staged, which no edit could be stored into).
    var editedShot: EditedShot? {
        EditedShot.following(shots: shots, previewShotID: previewShotID, activeShotID: activeShotID)
    }

    // MARK: Media

    /// The files the project holds as media, in the order added — the
    /// document's list, from which each launch asks the media registry for
    /// the inputs (ARCHITECTURE.md, "Media inputs and the Library's Media
    /// tab"). An item whose file is missing stays listed and dormant.
    var media: [ProjectMedia] = []

    /// Movie and audio file durations by item, loaded as each registers, so
    /// the Library shows a file's length where it shows a still's size.
    var mediaDurations: [MediaID: TimeInterval] = [:]

    /// Each media item's picture size in pixels, read from the file as it
    /// registers — an image's pixel size with its orientation applied, a
    /// movie's track size with its transform applied, the text canvas —
    /// so a layer can be fitted to the picture before the input has
    /// delivered a frame (``newLayerFrame(forInput:)``).
    var mediaSizes: [MediaID: CGSize] = [:]

    /// The content types the registered media providers open — what the
    /// Library's importer and drop target accept. Snapshotted after the
    /// plug-ins activate.
    private(set) var mediaContentTypes: [UTType] = []

    /// The media registry the media plug-in registers its providers into and
    /// the model resolves each added file through.
    @ObservationIgnored let mediaRegistry = MediaRegistry()

    // MARK: Windows

    /// The windows the project holds as inputs, in the order added — the
    /// document's list, from which each launch makes the window inputs
    /// (ARCHITECTURE.md, "Window capture"). A record whose window is not
    /// open stays listed, its input waiting for the window.
    var windows: [ProjectWindow] = []

    /// Each window's size in points as the picker listed it when it was
    /// added, so a new layer can be fitted to the window before the input
    /// has delivered a frame (``newLayerFrame(forInput:)``). Session state:
    /// a window loaded from a project is measured from its first frame
    /// instead.
    var windowSizes: [InputID: CGSize] = [:]

    /// Whether the Add Window sheet is up (``WindowPickerSheet``). Session
    /// state held here rather than in a view because four surfaces open it
    /// — the Windows section's heading and the Add Shot menu in the
    /// sidebar, over the shot bank, and in the menu bar — and one view,
    /// ``ContentView``, presents it.
    var isWindowPickerPresented = false

    // MARK: Applications

    /// The applications the project holds as audio inputs, in the order
    /// added — the document's list, from which each launch makes the
    /// application inputs (ARCHITECTURE.md, "Application audio"). A record
    /// whose application is not running stays listed, its input waiting for
    /// the application.
    var applications: [ProjectApplication] = []

    /// Whether the Add Application sheet is up (``ApplicationPickerSheet``).
    /// Session state held here, like ``isWindowPickerPresented``, so the
    /// sidebar opens it and ``ContentView`` presents it.
    var isApplicationPickerPresented = false

    // MARK: Layer editing session state

    /// The selected layer's index in the followed shot's bottom-to-top
    /// `layers` array, or `nil` for no selection — session state, like what
    /// is staged, never part of the document. It lives here rather than in
    /// the editor because three surfaces read and write it: the layer list,
    /// the handles on the monitor, and the Layer menu. Read it through
    /// ``selectedLayer``, which validates it: an index the followed shot no
    /// longer has is no selection, never a crash.
    var selectedLayerIndex: Int?

    /// Whether a resize keeps the selected layer's proportion — the
    /// inspector's lock, which the handles on the monitor honor too, the
    /// way Keynote's Constrain Proportions governs both the fields and the
    /// drag (Shift on a handle holds it as well). **On by default**: a
    /// resize that keeps the picture's proportion is the common one, and a
    /// stretch is the accident (Larry, 2026-09-09). Session state, so a
    /// launch starts locked.
    var holdsLayerAspect = true

    /// Whether the inspector's layer monitor is disclosed. **Closed by
    /// default** and not drawn while closed (Larry, 2026-09-10): a monitor
    /// at display rate is a cost the column should pay only when the
    /// operator is judging an effect, so the disclosure builds the
    /// `MTKView` on opening and tears it down on closing. Session state,
    /// like the inspector itself.
    var isLayerMonitorDisclosed = false

    /// The main window's undo manager, handed over by `ContentView` so
    /// every layer-tree edit can register the shot it replaced
    /// (ARCHITECTURE.md, "Direct manipulation, drag-to-reorder, and undo in
    /// the layer-tree editor"). Weak: the window owns it.
    weak var undoManager: UndoManager?

    /// The followed shot as it was when the gesture in progress began, or
    /// nil between gestures. While set, ``applyShotEdit(_:_:)`` registers
    /// nothing — a slider or handle drag edits at gesture rate, and the
    /// whole drag is one undo step, registered by ``endLayerGesture(_:)``.
    var layerGestureSnapshot: Shot?

    /// The transition kind the next shot switcher tap takes with
    /// (GLOSSARY.md, "Transition") — session state bound from `ContentView`'s
    /// transition picker, never part of the saved document — but remembered
    /// machine-locally with the rest of the operator's position, so a launch
    /// arms what was armed (``recordSessionPosition()``). Starts on
    /// ``TakeTransitionKind/default``, so each take resolves the taken shot's
    /// own ``Shot/defaultTransition`` until the operator overrides it with an
    /// explicit kind (ARCHITECTURE.md, "Per-shot default transitions"). The
    /// switcher itself still always reports the choice it used, never guesses
    /// at intent.
    var takeTransitionKind: TakeTransitionKind = .default {
        didSet { recordSessionPosition() }
    }

    /// The frame edge the next wipe reveals the incoming shot from — session
    /// state bound from the switcher's edge picker, read only while
    /// ``takeTransitionKind`` is ``TakeTransitionKind/wipe``; remembered
    /// like ``takeTransitionKind``.
    var wipeEdge: WipeEdge = .left {
        didSet { recordSessionPosition() }
    }

    /// The built-in shader the next shader transition reveals the incoming
    /// shot with — session state bound from the switcher's shader picker,
    /// read only while ``takeTransitionKind`` is
    /// ``TakeTransitionKind/shader``; remembered like ``takeTransitionKind``.
    var shaderName: TransitionShader = .iris {
        didSet { recordSessionPosition() }
    }

    /// The length, in seconds, of the next timed take — the panel's one
    /// **rate** knob (2026-09-13), the AUTO rate of a hardware switcher:
    /// every dissolve, wipe, and shader transition runs this long, whether
    /// the kind was armed explicitly or came from the taken shot's own
    /// ``Shot/defaultTransition`` (the shot keeps its kind, edge, and shader;
    /// the rate is the operator's). A cut has no length, so the rate is
    /// simply not read for one. Session state bound from the panel's
    /// duration field and stepper, remembered like ``takeTransitionKind``.
    /// Set through ``setTakeTransitionDuration(_:)``, which clamps to
    /// ``takeTransitionDurationRange``.
    var takeTransitionDuration: TimeInterval = Transition.defaultDissolveDuration {
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
    /// cadence — the program relay's twin, one bus over (GLOSSARY.md,
    /// "Preview"). Emptied whenever ``previewShotID`` goes nil, so a cleared
    /// preview reads as empty rather than as a frozen frame.
    @ObservationIgnored let previewRelay = ProgramFrameRelay()

    /// The latest mix tick's meter readings, handed to the strip meters to
    /// draw — the audio mirror of ``programRelay``: the meter drain writes
    /// it, ``meterDisplayLink`` samples it at display cadence, and no reading
    /// passes through SwiftUI observation (ARCHITECTURE.md, "Per-strip
    /// meters").
    @ObservationIgnored let meterRelay: MeterRelay

    /// The one display link every meter and peak readout on screen shares,
    /// reading ``meterRelay`` once a frame and moving the meters' layers
    /// outside SwiftUI's graph (ARCHITECTURE.md, "Meters off the SwiftUI
    /// clock"). Idle until a meter is in a window.
    @ObservationIgnored let meterDisplayLink: MeterDisplayLink

    /// The same mix ticks as app-tier plug-ins follow them: the meter drain
    /// folds each block in, and a connection that subscribed is sent its
    /// window of them at most ten times a second (`tingra/meters`;
    /// PLUGINS.md, Decision 18). With no follower a block costs it one lock.
    @ObservationIgnored let meterFeed = MeterFeed()

    /// The host event bus. Its log sinks drain it (``start(launch:)``): the
    /// host's `FileSink` appending every event to ``logFile``, always, and
    /// one live view — the ``ConsoleEventSink`` printing the same lines to
    /// stdout when a developer runs the app from Xcode or
    /// `scripts/run-app.sh`, otherwise the host's `OSLogSink` as the system
    /// of record (EVENTS.md, "Sinks").
    ///
    /// Not `private`: every `tap` event is reported by the UI code that
    /// executes the action (a `Button`'s action closure, a picker's
    /// `onChange`), not by the model on the view's behalf — so `ContentView`
    /// calls `model.eventBus.tap(...)` directly (EVENTS.md, "The `tap`
    /// convention").
    @ObservationIgnored let eventBus = EventBus()

    /// The app's one log file, `~/Library/Logs/Tingra/Tingra.log` — the file
    /// the file sink appends to, and the one the Logging settings pane sizes,
    /// snapshots, and clears. One locator for both, so the sink and the pane
    /// cannot name different files (EVENTS.md, "File sink").
    @ObservationIgnored let logFile = LogFile()

    /// The master clock (see CLOCK.md).
    @ObservationIgnored let clock = HostClock()

    /// The input registry the plug-ins register into.
    @ObservationIgnored lazy var registry = InputRegistry(eventBus: eventBus)

    /// The authorization seam the permissions are read through — the real
    /// TCC reads in production, a scripted answer in tests.
    @ObservationIgnored private let authorization: any AuthorizationChecking

    /// Reads the system default microphone's input id — what a fresh
    /// project's mixer seeds its one strip on (``MixerStrip/seed(from:preferring:)``).
    /// The capture plug-in's `SystemDefaultInputs` in production, the same
    /// read the CLI's `--mic` default makes; a fixed answer in tests.
    @ObservationIgnored let defaultMicrophoneID: @Sendable () -> InputID?

    /// Where each system permission stands (Camera, Microphone, Screen
    /// Recording): the Permissions settings pane's model, refreshed on every
    /// app activation so a grant made in System Settings starts the inputs
    /// it unblocks when the operator returns (``applyNewlyGranted(_:)``).
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
    /// here, keyed by the destination URL — never the project document, never
    /// an event, never a log.
    ///
    /// Filed in the shared keychain access group the app's entitlement
    /// declares, which is what makes the item reachable by a second Tingra
    /// binary later (DESTINATIONS.md, "Key sharing between the app and the
    /// daemon"). Named explicitly rather than left to the implicit default:
    /// an item written with no group lands in the *first* entry of the
    /// entitlement's list, so the group a key is filed under would otherwise
    /// be decided by the order of an XML array — the way the two would drift
    /// the moment a second group is ever added. ``DestinationStore`` takes
    /// the same group by default, so both writers agree.
    ///
    /// Internal rather than private since 2026-09-17, so the app tier's
    /// plug-in secrets (`PlugInSecretStore`) are filed in the same store and
    /// the same access group as the keys, from one construction.
    @ObservationIgnored let secureStorage: any SecureStorage = KeychainSecureStorage(
        accessGroup: KeychainSecureStorage.sharedAccessGroup())

    /// The operator's saved destinations (DESTINATIONS.md). Operator-global,
    /// not per-project: the app is the editor, and the daemon reads the same
    /// document so an agent can resolve "my Twitch" by name.
    ///
    /// Held as the writer of names and URLs only. Stream keys stay on
    /// ``secureStorage`` directly, under the account convention the store
    /// itself publishes (``DestinationStore/secureStorageAccount(for:)``), so
    /// the two can never disagree about where a key is filed.
    @ObservationIgnored lazy var destinationStore = DestinationStore(eventBus: eventBus)

    /// This project's destination references as loaded, held until the store
    /// read that turns them into panel rows completes.
    ///
    /// The two halves arrive separately — the document synchronously, the
    /// store from an actor — so the references wait here rather than the merge
    /// guessing at an empty store.
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
    /// ``streamStats`` and ``destinationStats``. One reading a second, kept
    /// newest-only by the session, so it runs on the main actor without
    /// anything queuing behind it.
    @ObservationIgnored var streamStatisticsTask: Task<Void, Never>?

    /// The program tee: the one program drain (``programTask``) and the one
    /// program-audio drain (``programAudioTask``) hand every composited frame
    /// and mixed block here, and the tee passes them to whichever sessions
    /// are attached — the stream session while a stream is live, the
    /// recording session while recording — so both reuse the same program
    /// the monitor shows without a second `Compositor.programFrames()`
    /// consumer. Lock-guarded and nonisolated, so the drains run off the
    /// main actor (ARCHITECTURE.md, "Bounded frame streams").
    @ObservationIgnored let tee = ProgramTee()

    /// The task observing the bus for `stream.*` status events — the stream
    /// status is event-driven, never polled.
    @ObservationIgnored private var streamStatusTask: Task<Void, Never>?

    /// The active recording session, or nil when not recording.
    ///
    /// A **second** `StreamSession` carrying no destinations, running beside
    /// ``streamSession`` rather than inside it, so the recording and the
    /// stream start and stop independently (ARCHITECTURE.md, "Recording in
    /// the app"). This is not a second *stream*: v1's one-active-session rule
    /// governs what is on air, and a session with no destination puts nothing
    /// on air.
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

    /// The on-disk marker of the stream this run has on air: written when
    /// the stream session goes live, removed when it stops and at a clean
    /// quit, and read at the next launch to offer resuming a stream the app
    /// died under (ARCHITECTURE.md, "Offering to resume a stream after the
    /// app dies").
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

    /// The program geometry and rate — a **project setting** (ARCHITECTURE.md,
    /// "The program format as a project setting"): 1080p30 until the project
    /// loads its own, changed by ``setProgramFormat(_:)``. Observed, so the
    /// monitors, the bank, and the status bar reshape with it.
    var format = ProgramFormat()

    /// The program geometry, for the layer inspector's pixel fields
    /// (``LayerInspectorUnit``).
    var programFormat: ProgramFormat {
        format
    }

    /// Changes the program's size and frame rate — live, at the next tick
    /// (``Compositor/setFormat(_:)``), and saved with the project.
    ///
    /// **Refused while streaming or recording**: the sinks' compression
    /// sessions are open at a size, so the format is a session-start
    /// setting there, as it is for the CLI. The Program menu's items are
    /// disabled then, and this refusal — a `program.format` error event
    /// carrying the `reason` — is what a macro or a later MCP tool meets, so
    /// no path can slip a change under a live session. The same format again
    /// changes nothing and saves nothing.
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

    /// The store of the **default project** — what a fresh install opens,
    /// what a launch falls back to when the last project cannot be reopened,
    /// and what the Data settings pane removes. The operator's own project
    /// files elsewhere are theirs, like recordings (ARCHITECTURE.md,
    /// "Projects as documents").
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

    /// The project-scoped storage of app-tier plug-ins, by plug-in id: the
    /// document's `plugInData` key, held opaque and written back as read so
    /// a project opened without a plug-in loses nothing of its data
    /// (PLUGINS.md, Decision 7; ``plugInProjectData(for:)``).
    @ObservationIgnored var plugInData: [String: JSONValue] = [:]

    /// The host's monitor overlay registry: what the first-party and
    /// third-party overlay plug-ins register into through the plug-in
    /// context (PLUGINS.md, Decision 53). Read once, after activation, into
    /// ``monitorOverlayCatalog``.
    @ObservationIgnored private let monitorOverlayRegistry = MonitorOverlayRegistry()

    /// Every registered monitor overlay, in the order the Overlays submenus
    /// list them: the main-actor snapshot a menu and a draw read
    /// (``fillMonitorOverlayCatalog(with:)``).
    var monitorOverlayCatalog = MonitorOverlayCatalog.empty

    /// The open project's monitor overlays, as the document holds them, or
    /// `nil` when the operator has never changed them, which reads as
    /// ``defaultMonitorOverlays`` and saves as an absent key (PLUGINS.md,
    /// Decision 55).
    var monitorOverlaySettings: MonitorOverlaySettings?

    /// The host's tool registry: what the MCP endpoint app-tier plug-ins
    /// call lists and dispatches against, and what host-tier plug-ins
    /// register tools into through the plug-in context (PLUGINS.md,
    /// Decision 10). The first-party program tools (`ProgramToolsPlugIn`)
    /// register into it at boot beside the capture and generator plug-ins.
    @ObservationIgnored let toolRegistry = ToolRegistry()

    /// The host's resource registry: what the MCP endpoint lists, reads,
    /// and subscribes plug-ins to — the session, the program, and the
    /// inputs, rendered from this model's state (`EngineResources`;
    /// PLUGINS.md, Phase 2). Filled once the engine is up.
    @ObservationIgnored let resourceRegistry = ResourceRegistry()

    /// The projects opened, created, or saved as through the File menu, most
    /// recent first — the Open Recent submenu's rows. Kept by the system's
    /// document controller, which also feeds the Apple menu's Recent Items
    /// and the Dock; mirrored here so the menu observes a change.
    var recentProjectURLs: [URL] = []

    /// A project the Finder asked the app to open while the engine was still
    /// booting — a double-clicked document — opened once ``start(launch:)`` has
    /// the show up (``openProjectWhenReady(_:)``).
    @ObservationIgnored var pendingProjectURL: URL?

    /// Where the operator's position — active preset, program shot, staged
    /// shot — persists between launches (``SessionPreferences``), scoped to
    /// the open project once its id is known.
    @ObservationIgnored var sessionPreferences = SessionPreferences()

    /// The position recorded by the last run, read at the top of
    /// ``loadProject()`` before any assignment can overwrite it, and consumed
    /// once by ``establishSessionPreset()``; nil after that, and on every
    /// launch that seeds a fresh project. While it is set, nothing records
    /// the position (``recordSessionPosition()``).
    @ObservationIgnored var restoredPosition: SessionPosition?

    /// The pending debounced autosave, if any — each edit restarts the delay
    /// so a slider drag coalesces into one write (see ``scheduleAutosave()``).
    @ObservationIgnored var autosaveTask: Task<Void, Never>?

    /// Whether ``removeAllData()`` has run: from then on nothing autosaves,
    /// so the document the operator just removed is not written back by the
    /// next edit or by the quit that follows (``saveProject()``).
    @ObservationIgnored var isRemovingData = false

    /// What the app has saved on this Mac, and the way to remove all of it —
    /// the Data settings pane's model, built over the same project store,
    /// destination store, and secret store this engine writes through, so
    /// the pane and the engine cannot name different files
    /// (``AppDataStore``).
    ///
    /// The preferences domain is the bundle identifier — the domain
    /// `UserDefaults.standard` persists under — falling back to the process
    /// name, which is what the standard defaults use for an unbundled
    /// process.
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

    /// The stream history — every streamed session and the figures over all
    /// of them, the Streaming settings pane's history — kept in
    /// ``streamHistoryStore`` (``StreamHistoryModel``). Lazy, so a launch
    /// that neither streams nor opens the pane reads nothing.
    @ObservationIgnored private(set) lazy var streamHistory = StreamHistoryModel(
        store: streamHistoryStore, eventBus: eventBus)

    /// Where the stream history persists: beside the project store's default
    /// document in the app, a temporary folder in tests. Injected because
    /// the model records a session at every `stream.started` it is handed,
    /// and a test that hands it one must not write into the operator's own
    /// history — which one did on 2026-10-13, as a session with no
    /// destination.
    @ObservationIgnored private let streamHistoryStore: StreamHistoryStore

    /// Which installed plug-ins are turned off — the Plug-ins settings
    /// pane's model, over the same `plug-ins.json` the bundle loader reads
    /// at every launch (``PlugInEnablementModel``, PLUGINS.md, Decisions 34
    /// and 36).
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

    /// A renderer for the shot bank's thumbnails over the given Core Image
    /// context — the monitors' shared one — resolving layer chains through
    /// the same ``videoEffectProviders`` the compositor's renderer reads,
    /// so a tile composes a shot exactly as program would
    /// (ARCHITECTURE.md, "Shot thumbnails are the shot"). Its effect
    /// instances are its own: an effect may carry state, and a monitor
    /// never shares the compositor's.
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
    /// each layer's authored chain through ``videoEffectProviders``, so
    /// `TingraComposition` never depends on the host's effect registry
    /// (ARCHITECTURE.md, "Per-layer video effects").
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
    /// to the operator's chosen device (GLOSSARY.md, "Monitor"). A **sink**
    /// on the program-audio drain's tee, never a second bus — so nothing it
    /// does can change what viewers hear (ARCHITECTURE.md, "The monitor
    /// path"). Nothing opens until a device is chosen.
    @ObservationIgnored let monitor: any AudioMonitor

    /// Where the monitor's device and level persist: machine-local
    /// preferences, not the project document (a project carried to another
    /// Mac would name a device that does not exist) and not session state
    /// (headphones do not change between launches).
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

    /// Which pass needs each input running, so an input both need — a video
    /// file with sound, shown by a layer and heard on an unmuted strip — is
    /// started by the first and stopped only by the last (``InputClaims``).
    /// ``activeInputs`` and ``activeAudioInputs`` say what each pass is
    /// using; these claims alone decide `start()` and `stop()`.
    @ObservationIgnored var inputClaims = InputClaims()

    /// The task draining the compositor's program stream into the relay.
    @ObservationIgnored private var programTask: Task<Void, Never>?

    /// The task draining the compositor's preview frames into the preview
    /// relay. Unlike the program drain it tees nowhere: nothing on preview is
    /// visible to viewers (GLOSSARY.md, "Preview"), so it never reaches a
    /// stream or recording sink.
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// The task draining the mixer's program-audio stream, teeing each mixed
    /// block into the active session while a stream is live (there is no
    /// audio preview yet — that monitoring slice is a later iteration).
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
    /// engine boots; the main window's subtitle ends in "Safe Mode" while it
    /// is set.
    private(set) var safeModeTrigger: PlugInSafeModeTrigger?

    /// Every host-tier plug-in this launch met — the compiled-in ones and
    /// each bundle in the plug-in folders, in one state apiece — or `nil`
    /// until the engine has booted. The same report `tingra-cli plug-ins`
    /// prints; the Plug-ins settings pane lists it (PLUGINS.md, Decisions
    /// 35 and 36). Set once, as the plug-ins activate: what loaded cannot
    /// change until the next launch.
    private(set) var plugInReport: PlugInLoadReport?

    /// Whether any ``applyConfiguration()`` pass has completed, so the first
    /// pass establishes the session preset — seeding a fresh project around
    /// whichever of the first discovered display and camera started — and
    /// later passes only sync inputs.
    @ObservationIgnored var hasAppliedConfiguration = false

    /// Inputs whose last start attempt ended ``CaptureInputError/startedSilent(_:within:)``
    /// — listed by macOS, started without error, and delivering nothing
    /// (a built-in camera behind a closed lid, typically).
    ///
    /// A pass skips these rather than paying the verification window again
    /// for a device nothing has changed about, and the set is cleared by the
    /// things that can change it: any device connecting (a lid opening
    /// connects the built-in display, so that case rides on the same event),
    /// a permission grant, or the operator asking for the input — clicking
    /// its sidebar row, or choosing it in the inspector's Input popup.
    @ObservationIgnored var silentInputs: Set<InputID> = []

    /// Whether a ``reconfigure()`` pass is currently running. `reconfigure()`
    /// suspends at `input.start()`/`stop()`, so without this guard requests
    /// arriving together — the boot call, a device event, an edit that
    /// references a new input — would interleave and race the input
    /// start/stop.
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

    /// Creates the model. The engine boots in ``start(launch:)`` when the window
    /// appears, not here.
    ///
    /// - Parameters:
    ///   - monitor: The audio output path the operator monitors through
    ///     (the real `AVAudioEngine`-backed one by default; a double in
    ///     tests, so no audio hardware is needed).
    ///   - monitorPreferences: Where the monitor device and level persist.
    ///   - authorization: Where the system permissions are read from (the
    ///     real TCC reads by default; a scripted answer in tests).
    ///   - snapshotPreferences: Where the snapshots folder persists (the
    ///     standard defaults by default; a throwaway suite in tests, so a test
    ///     never writes into the operator's own snapshots folder).
    ///   - recordingPreferences: Where the recordings folder and container
    ///     persist (the standard defaults by default; a throwaway suite in
    ///     tests, for the same reason).
    ///   - streamingPreferences: Where the stream's compression choices
    ///     persist (the standard defaults by default; a throwaway suite in
    ///     tests).
    ///   - keepAwakePreferences: Where the Keep Mac Awake choice persists
    ///     (the standard defaults by default; a throwaway suite in tests).
    ///   - keepAwake: What the Mac is held awake through while a session
    ///     runs (the system-backed one by default; a double in tests, so no
    ///     test takes a power assertion).
    ///   - liveStreamRecord: The marker of the stream on air (the file in
    ///     Tingra's Application Support folder by default; one over a
    ///     temporary folder in tests).
    ///   - streamHistoryStore: Where the stream history persists (the file
    ///     in Tingra's Application Support folder by default; one over a
    ///     temporary folder in tests).
    ///   - defaultMicrophoneID: Reads the system default microphone, which a
    ///     fresh project's mixer seeds on (the capture plug-in's read by
    ///     default; a fixed answer in tests).
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
    /// - Parameter launch: Whether this launch is in safe mode, which loads
    ///   no plug-in bundles, and the operator's answer to the offer made
    ///   after an unclean exit, when one was made (PLUGINS.md, Decisions 31
    ///   and 32).
    func start(launch: SafeModeLaunch = .normal) async {
        guard !started else { return }
        started = true
        safeModeTrigger = launch.trigger

        // The log sinks, attached before the first event so none is missed
        // (EVENTS.md, "Sinks"). The log file always, so every run records
        // somewhere an operator can find and share. Then one live view: the
        // log file's lines on stdout when a developer runs the app from Xcode
        // or `scripts/run-app.sh` (``ConsoleEventSink``), and otherwise OSLog
        // as the system of record. Never both: Xcode's console shows the
        // unified log too, so both would print every event twice there.
        logSinkTasks = [eventBus.attach(FileSink(url: logFile.url))]
        if LaunchEnvironment.logsToConsole {
            logSinkTasks.append(eventBus.attach(ConsoleEventSink()))
        } else {
            logSinkTasks.append(eventBus.attach(OSLogSink()))
        }
        // The first line of every log names the build it came from — the app
        // and macOS versions and the Mac's model — so a shared log can be
        // lined up with the report it arrived with (``LaunchDiagnostics``).
        eventBus.app(LaunchDiagnostics.eventName, domain: .platform, params: LaunchDiagnostics().params)
        // The safe-mode offer's click happened before there was anywhere to
        // record it, so it goes on the bus now, ahead of its effect.
        launch.reportOfferTap(on: eventBus)
        // Observe the bus for `stream.*` status changes before anything can
        // stream, so no status event is missed (event-driven, never polled).
        // One consumer, two handlers. Attached here — before the plug-ins
        // activate — so neither a `stream.*` status change nor the session's
        // first `device.*` event can be missed; a second subscription created
        // later in this method could not make that promise.
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
        // one, so a session log opens with what TCC allowed at launch; from
        // here on each app activation re-reads it (never a poll), and a grant
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
        // The recordings folder's free space is read once the engine is up and
        // again whenever the folder, the container, or a finished recording
        // can have changed the answer — never on a timer.
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
        // before the lists are used: each item becomes an input the
        // sidebar, the layer editor, and the strips then see.
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
        // from discovery — the seed policy (one strip, on the system default
        // microphone, unmuted) is the fallback when the document authored
        // none (a fresh project, or one written before routing landed).
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
        // Both drains run **off the main actor** (`Task.detached`): the relays
        // and the tee are lock-guarded, so a frame never waits for the main
        // thread, and a busy main thread can only cost the monitor a draw,
        // never queue frames (ARCHITECTURE.md, "Bounded frame streams").
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
                // While a stream is live, tee the same program frame into the
                // session — one program drain feeds both the preview and the
                // stream, so the compositor's single-consumer contract holds.
                // The recording session is the second leaf on the same tee,
                // fed the identical frame: both sinks record the same program
                // (ARCHITECTURE.md, "Recording in the app").
                tee.yield(frame)
                if !sawFrame {
                    sawFrame = true
                    // A one-time milestone (not per-frame traffic): confirms the
                    // compositor is producing program frames into the preview
                    // relay at all — the background canvas ticks from the first
                    // frame even before an input delivers.
                    eventBus.event("preview.firstFrame", domain: .composition)
                }
            }
        }

        // The program mix runs from boot like the compositor — a live canvas
        // of silence until a strip's device delivers. Its one drain tees each
        // mixed block into the session while a stream is live and into the
        // monitor while the operator is listening (the audio mirror of the
        // program-frame drain above). Both are leaves on the same tee, so
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
        // and the post-fader master reading per block, into the relay the
        // meters sample at display cadence — per-block data, never the event
        // bus (EVENTS.md).
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

        // Last, with the project open, its destinations merged, and the
        // program running: the operator can see what would go on air before
        // answering. The safe mode offer was answered before the boot.
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

    /// Turns holding the Mac awake during a stream or a recording on or off,
    /// persisting the choice as a machine-local preference. It takes effect
    /// at once, on a session already running too.
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
    /// before the process exits.
    ///
    /// Called from the app delegate for **every** quit AppKit dispatches
    /// (``TingraAppDelegate/applicationShouldTerminate(_:)``). It emits one
    /// `app.terminating` event (domain `platform`) carrying the cause and
    /// whether a recording or a stream was open, writes a pending debounced
    /// autosave at once — an edit made in the second before the quit would
    /// otherwise be lost with its timer — closes the stream history's entry
    /// for a stream still on air (``StreamHistoryModel``), finalizes the
    /// recording the way
    /// quitting always has — an unfinalized movie is an unplayable one —
    /// then shuts the bus down and **awaits every log sink's drain**, because
    /// delivery is asynchronous and an event still buffered when the process
    /// exits was never logged. Nothing else is torn down: the stream, the
    /// inputs, and the compositor go with the process, as they did before.
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
        // A clean quit while live is the operator's choice: nothing to
        // offer at the next launch, even if the stream's stop event never
        // reaches the observer before the process exits.
        liveStreamRecord.remove()
        // The stream goes with the process and reports no end of its own, so
        // the history's open entry is closed here — otherwise a quit on air
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

    /// Removes everything the app has saved on this Mac — the project
    /// document, the destinations, the stream keys, the preferences, and the
    /// log session counter; never a recording — and stops the engine saving
    /// anything further, so the caller can quit and the next launch is a
    /// first run (ARCHITECTURE.md, "The Data settings pane").
    ///
    /// The pending autosave is cancelled and every later save refused
    /// **before** the files go, because the engine still holds the show in
    /// memory: an autosave landing after the removal would write the
    /// document straight back, and the quit's own flush would do the same.
    /// The engine keeps running — the stream, the recording, and the
    /// compositor go with the process, as they do on every quit — so a
    /// recording in flight is still finalized by the quit that follows.
    ///
    /// Saving stays off even when a kind could not be removed: the caller
    /// shows what remains rather than quitting, and an edit made then must
    /// not recreate what was just removed.
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

    /// This transition at another length: the same kind, edge, and shader
    /// over `duration` seconds — a cut unchanged, since it has no length.
    /// How the panel's one rate knob applies to whatever transition a take
    /// resolved to, a shot's own default included.
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
/// "Transition") — the UI's session-state selection, mapped to a concrete
/// ``Transition`` (with the selected wipe edge or shader, and the panel's
/// take duration) at take time.
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
/// chains against, shared between the main actor (which fills it at boot
/// from the effect registry) and the compositor's tick task (which reads
/// it per chain rebuild).
///
/// A reference box because the renderer factory is `@Sendable` and a
/// `Mutex` is non-copyable, so the lock cannot be captured directly; the
/// box is filled once, before the compositor starts.
///
/// `nonisolated` because the module compiles under main-actor default
/// isolation: the box carries its own `Mutex`, and the tick task reads it
/// off the main actor.
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
