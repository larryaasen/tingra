//
//  StreamSession.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import TingraEventBus
import TingraPlugInKit

/// One live stream: the host's session orchestration for the v1 pipeline —
/// one video source and one audio input feeding **N destination legs**.
///
/// The program is one stream with one `T0`, so multiple destinations are one
/// session fanned out, never N sessions: N sessions would each re-pick `T0`
/// and carry different PTS per destination for no benefit (ARCHITECTURE.md,
/// "Multiple destinations"). Each leg owns its own ``StreamingService`` — and
/// therefore its own compression session — so fan-out costs one encoder per
/// destination; the seam has no one-encode/N-muxer split to exploit.
///
/// The session owns the shared timeline (`T0` at start; every buffer is
/// rebased onto it before reaching every leg, per CLOCK.md "Timestamp
/// rules"), delivers the program audio at its source's cadence, reports the
/// CLI.md status events (`stream.started`, `stream.stats`, `stream.reconnecting`,
/// `stream.reconnected`, `stream.stopped`) on the event bus as `event`-group
/// events in the `output` domain, and drives the reconnect policy when a
/// service reports a connection loss.
///
/// **Legs are independent.** The attempt budget and the stability window are
/// per leg, so one destination dropping never takes another down. A leg whose
/// budget is exhausted is reported (`stream.destination.lost`) and stays dead
/// for the rest of the run while the others keep streaming; the session ends
/// with ``Outcome/connectionLost`` only when the **last** live leg is lost.
///
/// **Start is best effort.** Every leg is connected at start; a leg the
/// destination rejects is reported (`stream.destination.rejected`) and stays
/// dead — it does *not* enter the reconnect budget, which governs mid-stream
/// losses only. ``run()`` throws only when *every* leg was rejected, so a
/// single-destination session behaves exactly as it did before fan-out.
///
/// The program video reaches the session through a ``VideoSource``:
/// - ``VideoSource/input(_:)`` is the CLI's single-input path — the session
///   paces that one input through ``ProgramPacer`` (tick-paced, latest-wins)
///   and owns its device lifecycle (`start()`/`stop()`).
/// - ``VideoSource/program(_:)`` is the app's compositor path — an
///   already tick-paced program-frame stream (`Compositor.programFrames()`),
///   consumed as-is with no second pacing. The compositor and its inputs are
///   owned by the caller, so the session starts and stops nothing on that
///   side; it only rebases each frame onto `T0` and delivers it.
///
/// The program audio mirrors it through an ``AudioSource``:
/// - ``AudioSource/input(_:)`` is the CLI's pass-through microphone — the
///   session owns its device lifecycle and passes its buffers through at
///   capture cadence.
/// - ``AudioSource/program(_:)`` is the app's mixer path — the already
///   mix-tick-paced program audio (`AudioMixer.programAudio()`), consumed
///   as-is; the mixer and its inputs are owned by the caller.
///
/// Either way the reconnect machinery, the stability window, the periodic
/// stats, the duration timer, and the media pumps are identical — the app
/// reuses the proven CLI streaming lifecycle rather than rebuilding it
/// (ARCHITECTURE.md, "Streaming the program", "The audio mixer").
///
/// `tingra-cli stream` drives an ``VideoSource/input(_:)`` session directly;
/// the `serve` daemon owns one per `stream_start` tool call; the phase-3 app
/// drives a ``VideoSource/program(_:)`` session from the compositor and the
/// mixer.
public actor StreamSession {
    /// One destination the program fans out to: where it goes, and the
    /// service that takes it there.
    ///
    /// The `id` is the leg's stable identity in the status events
    /// (`destination`), so a script or an agent can tell one leg's
    /// `stream.stats` from another's. Callers mint it: the CLI numbers its
    /// `--url` occurrences, the app passes the saved destination's id, the
    /// daemon generates one per requested destination. Ids are labels, not
    /// keys — the session indexes legs positionally, so a caller that repeats
    /// an id only produces confusing events, never crossed state.
    public struct DestinationLeg: Sendable {
        /// The leg's stable identity in status events.
        public let id: String

        /// Where this leg streams to. Held for reconnects; its stream key
        /// never reaches the bus.
        public let destination: Destination

        /// The streaming service delivering the program to ``destination``
        /// (from the provider its URL scheme resolved to).
        public let service: any StreamingService

        /// Creates a destination leg.
        ///
        /// - Parameters:
        ///   - id: The leg's stable identity in status events.
        ///   - destination: Where this leg streams to.
        ///   - service: The streaming service for this destination.
        public init(id: String, destination: Destination, service: any StreamingService) {
            self.id = id
            self.destination = destination
            self.service = service
        }
    }

    /// One leg's mutable delivery state — the per-leg half of the reconnect
    /// policy, kept parallel to ``legs`` by index.
    private struct LegState {
        /// Whether this leg is still delivering. A leg goes dead when the
        /// destination rejected it at start, or when its reconnect budget
        /// ran out; a dead leg emits no stats and is never revived.
        var isLive = false

        /// When this leg's last successful reconnect happened on the master
        /// clock — how its next loss is classified as the same outage (within
        /// the policy's stability window) or a fresh one.
        var lastRecoveryTime: CMTime?

        /// The reconnect attempts left for this leg's current outage.
        var remainingReconnectAttempts = 0
    }

    /// How the session's program video is produced.
    public enum VideoSource: Sendable {
        /// A single capture input the session paces itself with
        /// ``ProgramPacer`` and whose device lifecycle it owns — the CLI's
        /// one-camera pipeline.
        case input(any Input)

        /// An already tick-paced program-frame stream, consumed as-is — the
        /// compositor's program output. The caller owns the compositor and
        /// its inputs; the session paces and starts nothing on this side.
        case program(AsyncStream<CapturedFrame>)
    }

    /// How the session's program audio is produced — the audio mirror of
    /// ``VideoSource``.
    public enum AudioSource: Sendable {
        /// A single capture input whose device lifecycle the session owns,
        /// passed through at capture cadence — the CLI's one-microphone
        /// pipeline.
        case input(any Input)

        /// The mixer's already-paced program audio, consumed as-is — one
        /// mixed block per mix tick. The caller owns the mixer and its
        /// inputs; the session starts and stops nothing on this side.
        case program(AsyncStream<CapturedAudio>)
    }

    /// The session control knobs from the CLI option surface (CLI.md:
    /// `--reconnect`, `--reconnect-delay`, `--stats-interval`,
    /// `--duration`).
    public struct Policy: Sendable, Equatable {
        /// Reconnection attempts on connection loss (0 disables).
        public var reconnectAttempts: Int

        /// Delay between reconnection attempts, in seconds.
        public var reconnectDelaySeconds: Int

        /// How often `stream.stats` events are emitted, in seconds (0
        /// disables).
        public var statsIntervalSeconds: Int

        /// Automatic stop after this many seconds, if set.
        public var durationSeconds: Int?

        /// How long a reconnected stream must survive before it counts as
        /// recovered. A connection that drops again within this window is
        /// the same outage, so the attempt budget keeps draining instead
        /// of resetting — otherwise a destination that accepts every
        /// publish and kills the connection moments later (the
        /// rejected-stream-key shape) would reconnect forever.
        public var stabilitySeconds: Int

        /// Creates a policy. Defaults mirror CLI.md's option defaults.
        ///
        /// - Parameters:
        ///   - reconnectAttempts: Reconnection attempts on connection loss.
        ///   - reconnectDelaySeconds: Delay between attempts, in seconds.
        ///   - statsIntervalSeconds: Stats cadence in seconds (0 disables).
        ///   - durationSeconds: Automatic stop after this many seconds.
        ///   - stabilitySeconds: How long a reconnect must survive to
        ///     count as recovered.
        public init(
            reconnectAttempts: Int = 3,
            reconnectDelaySeconds: Int = 2,
            statsIntervalSeconds: Int = 5,
            durationSeconds: Int? = nil,
            stabilitySeconds: Int = 10
        ) {
            self.reconnectAttempts = reconnectAttempts
            self.reconnectDelaySeconds = reconnectDelaySeconds
            self.statsIntervalSeconds = statsIntervalSeconds
            self.durationSeconds = durationSeconds
            self.stabilitySeconds = stabilitySeconds
        }
    }

    /// Why a session ended. Start-time failures throw from ``run()``
    /// instead — an outcome describes a session that was live.
    public enum Outcome: String, Sendable {
        /// ``stop()`` was called: Ctrl-C / SIGTERM in the CLI, or
        /// `stream_stop` once the MCP server lands. Exit 0.
        case stopRequested

        /// The configured `--duration` elapsed. Exit 0.
        case durationElapsed

        /// The connection dropped and was not recovered within the
        /// reconnect policy. Maps to `connectionLost`, exit 75.
        case connectionLost

        /// The recording stopped and the session had nothing else to do — a
        /// record-only session (no destinations) whose file sink failed.
        /// Maps to `recordingFailed`, exit 70.
        ///
        /// A session with a live destination never ends this way: recording
        /// stays independent of streaming (CLI.md), and this is the one case
        /// that rule never had to cover (see ARCHITECTURE.md, "Recording in
        /// the app").
        case recordingFailed
    }

    /// How the program video is produced, or nil under `--no-video`.
    private let videoSource: VideoSource?

    /// How the program audio is produced, or nil under `--no-audio`.
    private let audioSource: AudioSource?

    /// The destination legs the program fans out to, in the order the caller
    /// listed them. Fixed for the session's lifetime — v1 adds and removes
    /// destinations between runs, never mid-stream.
    private let legs: [DestinationLeg]

    /// Each leg's delivery state, parallel to ``legs`` by index.
    private var legStates: [LegState]

    /// The recording service writing the program to a local file, or nil
    /// when `--record` was not given. A parallel compression sink: fed the
    /// same program media as the stream, but independent of it — it keeps
    /// writing across a reconnect gap and is always finalized on teardown,
    /// however the session ends (CLI.md, "Recording and control").
    private let recording: (any RecordingService)?

    /// Where the recording is written, when ``recording`` is present.
    private let recordingFile: RecordingFile?

    /// Whether recording has started, so the file is finalized exactly once
    /// on teardown and only after it actually opened.
    private var recordingStarted = false

    /// The session's compression and program settings.
    private let configuration: StreamConfiguration

    /// The reconnect/stats/duration policy.
    private let policy: Policy

    /// The master clock: `T0`, the program tick, and every pacing wait
    /// come from it (synthetic in tests).
    private let clock: any EngineClock

    /// The host's event bus, carrying the session's status events.
    private let eventBus: EventBus

    /// What this session calls itself on the two events that name the
    /// session rather than a destination (`stream.started`,
    /// `stream.stopped`), or nil to leave them as they have always been.
    ///
    /// A caller running **two** sessions at once needs to tell their events
    /// apart, and the app does exactly that: a streaming session beside a
    /// record-only one (ARCHITECTURE.md, "Recording in the app"). Every
    /// other session event already carries a `destination`, and a
    /// record-only session emits none of those, so these two are the whole
    /// ambiguity. Nil for the CLI and the daemon, which run one session and
    /// whose `--json` output is unchanged by an absent param.
    private let label: String?

    /// The session's finished signal: ``finish(_:)`` yields exactly one
    /// outcome and ``run()`` awaits it.
    private let outcome: AsyncStream<Outcome>
    /// The continuation ``finish(_:)`` resolves the session through.
    private let outcomeContinuation: AsyncStream<Outcome>.Continuation

    /// Whether the session has already finished, so a duplicate trigger
    /// (a signal racing the duration timer) cannot double-finish.
    private var finished = false

    /// Creates a session from a single capture input (the CLI's one-camera
    /// pipeline). At least one media side should be present; the caller has
    /// already resolved inputs and read the stream keys.
    ///
    /// - Parameters:
    ///   - videoInput: The video input the session paces itself, or nil for
    ///     an audio-only stream.
    ///   - audioInput: The audio input, or nil for a video-only stream.
    ///   - destinations: The destination legs the program fans out to, each
    ///     with the service its URL scheme resolved to.
    ///   - configuration: The compression and program settings.
    ///   - policy: The reconnect/stats/duration policy.
    ///   - clock: The master clock (synthetic in tests).
    ///   - eventBus: The host's event bus.
    ///   - recording: The recording service for `--record`, or nil for a
    ///     stream-only session.
    ///   - recordingFile: Where the recording is written; required when
    ///     `recording` is present, ignored otherwise.
    public init(
        videoInput: (any Input)?,
        audioInput: (any Input)?,
        destinations: [DestinationLeg],
        configuration: StreamConfiguration,
        policy: Policy,
        clock: any EngineClock,
        eventBus: EventBus,
        recording: (any RecordingService)? = nil,
        recordingFile: RecordingFile? = nil
    ) {
        self.init(
            videoSource: videoInput.map(VideoSource.input),
            audioSource: audioInput.map(AudioSource.input),
            legs: destinations,
            configuration: configuration,
            policy: policy,
            clock: clock,
            eventBus: eventBus,
            recording: recording,
            recordingFile: recordingFile
        )
    }

    /// Creates a single-destination session from a single capture input —
    /// the one-leg convenience over ``init(videoInput:audioInput:destinations:configuration:policy:clock:eventBus:recording:recordingFile:)``,
    /// still the common case (one camera, one microphone, one destination).
    ///
    /// - Parameters:
    ///   - videoInput: The video input the session paces itself, or nil for
    ///     an audio-only stream.
    ///   - audioInput: The audio input, or nil for a video-only stream.
    ///   - service: The streaming service (from the provider the
    ///     destination's URL scheme resolved to).
    ///   - destination: Where the program streams to.
    ///   - configuration: The compression and program settings.
    ///   - policy: The reconnect/stats/duration policy.
    ///   - clock: The master clock (synthetic in tests).
    ///   - eventBus: The host's event bus.
    ///   - recording: The recording service for `--record`, or nil for a
    ///     stream-only session.
    ///   - recordingFile: Where the recording is written; required when
    ///     `recording` is present, ignored otherwise.
    public init(
        videoInput: (any Input)?,
        audioInput: (any Input)?,
        service: any StreamingService,
        destination: Destination,
        configuration: StreamConfiguration,
        policy: Policy,
        clock: any EngineClock,
        eventBus: EventBus,
        recording: (any RecordingService)? = nil,
        recordingFile: RecordingFile? = nil
    ) {
        self.init(
            videoSource: videoInput.map(VideoSource.input),
            audioSource: audioInput.map(AudioSource.input),
            legs: [DestinationLeg(id: Self.soleLegID, destination: destination, service: service)],
            configuration: configuration,
            policy: policy,
            clock: clock,
            eventBus: eventBus,
            recording: recording,
            recordingFile: recordingFile
        )
    }

    /// Creates a session from already-paced program streams (the app's
    /// compositor and mixer path). The caller owns the compositor, the
    /// mixer, and their inputs; the session paces nothing and starts/stops
    /// no device — it rebases each program frame and mixed block onto `T0`
    /// and delivers them.
    ///
    /// - Parameters:
    ///   - programVideo: The compositor's program-frame stream, or nil for an
    ///     audio-only stream.
    ///   - programAudio: The mixer's program-audio stream, or nil for a
    ///     video-only stream.
    ///   - destinations: The destination legs the program fans out to.
    ///   - configuration: The compression and program settings.
    ///   - policy: The reconnect/stats/duration policy.
    ///   - clock: The master clock (the same one pacing the compositor and
    ///     the mixer).
    ///   - eventBus: The host's event bus.
    ///   - recording: The recording service, or nil for a stream-only session.
    ///   - recordingFile: Where the recording is written; required when
    ///     `recording` is present, ignored otherwise.
    public init(
        programVideo: AsyncStream<CapturedFrame>?,
        programAudio: AsyncStream<CapturedAudio>? = nil,
        destinations: [DestinationLeg],
        configuration: StreamConfiguration,
        policy: Policy,
        clock: any EngineClock,
        eventBus: EventBus,
        recording: (any RecordingService)? = nil,
        recordingFile: RecordingFile? = nil,
        label: String? = nil
    ) {
        self.init(
            videoSource: programVideo.map(VideoSource.program),
            audioSource: programAudio.map(AudioSource.program),
            legs: destinations,
            configuration: configuration,
            policy: policy,
            clock: clock,
            eventBus: eventBus,
            recording: recording,
            recordingFile: recordingFile,
            label: label
        )
    }

    /// Creates a single-destination session from already-paced program
    /// streams — the one-leg convenience over
    /// ``init(programVideo:programAudio:destinations:configuration:policy:clock:eventBus:recording:recordingFile:)``.
    ///
    /// - Parameters:
    ///   - programVideo: The compositor's program-frame stream, or nil for an
    ///     audio-only stream.
    ///   - programAudio: The mixer's program-audio stream, or nil for a
    ///     video-only stream.
    ///   - service: The streaming service.
    ///   - destination: Where the program streams to.
    ///   - configuration: The compression and program settings.
    ///   - policy: The reconnect/stats/duration policy.
    ///   - clock: The master clock (the same one pacing the compositor and
    ///     the mixer).
    ///   - eventBus: The host's event bus.
    ///   - recording: The recording service, or nil for a stream-only session.
    ///   - recordingFile: Where the recording is written; required when
    ///     `recording` is present, ignored otherwise.
    public init(
        programVideo: AsyncStream<CapturedFrame>?,
        programAudio: AsyncStream<CapturedAudio>? = nil,
        service: any StreamingService,
        destination: Destination,
        configuration: StreamConfiguration,
        policy: Policy,
        clock: any EngineClock,
        eventBus: EventBus,
        recording: (any RecordingService)? = nil,
        recordingFile: RecordingFile? = nil
    ) {
        self.init(
            videoSource: programVideo.map(VideoSource.program),
            audioSource: programAudio.map(AudioSource.program),
            legs: [DestinationLeg(id: Self.soleLegID, destination: destination, service: service)],
            configuration: configuration,
            policy: policy,
            clock: clock,
            eventBus: eventBus,
            recording: recording,
            recordingFile: recordingFile
        )
    }

    /// The leg id the single-destination convenience initializers mint, so a
    /// one-destination run reports a stable, obvious `destination` param
    /// instead of an invented number.
    private static let soleLegID = "destination"

    /// The designated initializer every public init funnels through.
    ///
    /// - Parameters:
    ///   - videoSource: How the program video is produced, or nil under
    ///     `--no-video`.
    ///   - audioSource: How the program audio is produced, or nil for a
    ///     video-only stream.
    ///   - legs: The destination legs the program fans out to.
    ///   - configuration: The compression and program settings.
    ///   - policy: The reconnect/stats/duration policy.
    ///   - clock: The master clock (synthetic in tests).
    ///   - eventBus: The host's event bus.
    ///   - recording: The recording service, or nil for a stream-only session.
    ///   - recordingFile: Where the recording is written; required when
    ///     `recording` is present, ignored otherwise.
    private init(
        videoSource: VideoSource?,
        audioSource: AudioSource?,
        legs: [DestinationLeg],
        configuration: StreamConfiguration,
        policy: Policy,
        clock: any EngineClock,
        eventBus: EventBus,
        recording: (any RecordingService)?,
        recordingFile: RecordingFile?,
        label: String? = nil
    ) {
        self.videoSource = videoSource
        self.audioSource = audioSource
        self.legs = legs
        self.legStates = Array(repeating: LegState(), count: legs.count)
        self.configuration = configuration
        self.policy = policy
        self.clock = clock
        self.eventBus = eventBus
        self.recording = recording
        self.recordingFile = recordingFile
        self.label = label
        (self.outcome, self.outcomeContinuation) = AsyncStream.makeStream(of: Outcome.self)
    }

    /// Requests a clean stop: flush compression, close the connection,
    /// report `stream.stopped`. ``run()`` then returns
    /// ``Outcome/stopRequested``. Safe to call more than once.
    public func stop() {
        finish(.stopRequested)
    }

    /// Runs the stream until it ends: starts the inputs and the service,
    /// pumps media on the shared timeline, and returns why the session
    /// ended after an orderly teardown.
    ///
    /// Throws only for start-time failures — an input that cannot start
    /// (authorization denied, device gone), or **every** destination
    /// rejecting the connection — so the caller can map them to error
    /// identifiers. A partial rejection is not a throw: the session goes live
    /// on the legs that connected. Once live, problems surface as events and
    /// an eventual outcome, never a throw.
    public func run() async throws -> Outcome {
        // Only a session-owned capture input is started here; a program
        // source is driven by the caller's compositor or mixer, already
        // running.
        if case .input(let videoInput) = videoSource {
            try await videoInput.start()
        }
        if case .input(let audioInput) = audioSource {
            try await audioInput.start()
        }

        // Recording opens before the network connection: a setup failure
        // fails the run before anything streams (the caller asked to record
        // and could not), while a later connection failure still finalizes
        // the file that was opened.
        if let recording, let recordingFile {
            do {
                try await recording.start(to: recordingFile)
            } catch {
                await stopInputs()
                throw error
            }
            recordingStarted = true
            eventBus.event(
                "recording.started",
                domain: .output,
                params: [
                    "path": .string(recordingFile.url.path),
                    "container": .string(recordingFile.container.rawValue),
                ]
            )
        }

        do {
            try await connectLegs()
        } catch {
            await finalizeRecording()
            await stopInputs()
            await stopServices()
            throw error
        }

        // The shared session start on the master clock: every sink sees
        // PTS = hostTime − T0 from here on (CLOCK.md, Timestamp rules).
        let t0 = clock.now
        eventBus.event("stream.started", domain: .output, params: startedParams)
        for index in legs.indices where legStates[index].isLive {
            eventBus.event("stream.destination.started", domain: .output, params: legParams(index))
        }

        let pumpTasks = startPumps(t0: t0)
        var watchTasks: [Task<Void, Never>?] = [watchStats(t0: t0), watchDuration(), watchRecording()]
        for task in watchConnections() {
            watchTasks.append(task)
        }

        var result: Outcome = .stopRequested
        for await first in outcome {
            result = first
            break
        }

        for task in watchTasks {
            task?.cancel()
        }
        for task in pumpTasks {
            task.cancel()
        }
        await stopInputs()
        await stopServices()
        // Finalize the recording last so it captures everything the pumps
        // delivered, however the session ended (stop, duration, or a lost
        // connection).
        await finalizeRecording()
        var stoppedParams: [String: EventValue] = ["reason": .string(result.rawValue)]
        if let label { stoppedParams["session"] = .string(label) }
        eventBus.event("stream.stopped", domain: .output, params: stoppedParams)
        return result
    }

    /// Connects every destination leg, best effort: a leg the destination
    /// accepts goes live, a leg it rejects is reported as an error event and
    /// stays dead for the run. A rejected leg does **not** enter the
    /// reconnect budget — that governs mid-stream losses only, so a
    /// destination that was wrong at start stays wrong rather than retrying
    /// against a typo.
    ///
    /// - Throws: The first leg's error when *every* leg was rejected (the
    ///   whole start failed, so the caller maps it to `connectionFailed`),
    ///   or ``StreamingServiceError/unsupportedDestination(_:)`` when the
    ///   session was given nothing to feed at all.
    ///
    /// **No destinations is legal when there is a recording** — that is the
    /// app's record-only session, a session whose only sink is a file
    /// (ARCHITECTURE.md, "Recording in the app"). What is refused is a
    /// session with no sink of any kind, which would pump the program into
    /// nothing.
    private func connectLegs() async throws {
        guard !legs.isEmpty else {
            guard recording == nil else { return }
            throw StreamingServiceError.unsupportedDestination(
                "A session needs at least one destination or a recording; neither was configured."
            )
        }
        var firstError: (any Error)?
        for index in legs.indices {
            do {
                try await legs[index].service.start(to: legs[index].destination)
                legStates[index].isLive = true
            } catch {
                if firstError == nil { firstError = error }
                reportDestinationRejected(index, error: error)
            }
        }
        // Best effort: one live leg is a live session. Only a clean sweep of
        // rejections fails the run, so a single-destination session throws
        // exactly where it always did.
        guard liveLegCount == 0, let firstError else { return }
        throw firstError
    }

    /// How many legs are still delivering.
    private var liveLegCount: Int {
        legStates.count { $0.isLive }
    }

    /// Reports a leg the destination rejected at start.
    ///
    /// An `error` event, not an outcome: with more than one destination the
    /// session is still live, so this follows the `recordingFailed`
    /// precedent — reported with a stable identifier so scripts and the
    /// operator see it, without changing the run's fate (CLI.md, "Status
    /// events").
    private func reportDestinationRejected(_ index: Int, error: any Error) {
        var params = legParams(index)
        params["identifier"] = .string(ErrorIdentifier.connectionFailed.rawValue)
        params["message"] = .string(
            "The destination rejected the connection and will not be streamed to: \(error)"
        )
        eventBus.error("stream.destination.rejected", domain: .output, params: params)
    }

    /// Reports a leg whose reconnect budget ran out mid-stream. The session
    /// keeps streaming to whatever is left; ``Outcome/connectionLost`` is the
    /// last live leg's job, not this one's.
    private func reportDestinationLost(_ index: Int, reason: String) {
        var params = legParams(index)
        params["identifier"] = .string(ErrorIdentifier.connectionLost.rawValue)
        params["message"] = .string(
            "The connection was lost and not recovered within \(policy.reconnectAttempts) reconnect "
                + "attempts; this destination stopped: \(reason)"
        )
        eventBus.error("stream.destination.lost", domain: .output, params: params)
    }

    /// The params identifying one leg on every per-leg event: its stable id
    /// and its URL. Flat, because an event param is a scalar (EVENTS.md), so
    /// the identity rides on each event rather than in a lookup table a
    /// consumer would have to build. The URL carries no secret — the stream
    /// key is held apart in ``Destination`` and composed inside the service.
    private func legParams(_ index: Int) -> [String: EventValue] {
        [
            "destination": .string(legs[index].id),
            "destinationUrl": .string(legs[index].destination.url.absoluteString),
        ]
    }

    /// Stops every leg's service on teardown — dead legs included, so a leg
    /// that died mid-run releases its connection with the rest rather than
    /// separately (each service is stopped exactly once, however it ended).
    private func stopServices() async {
        for leg in legs {
            await leg.service.stop()
        }
    }

    /// Stops the session-owned inputs, if present. A program source is left
    /// alone — its compositor or mixer and their inputs belong to the caller.
    private func stopInputs() async {
        if case .input(let videoInput) = videoSource {
            await videoInput.stop()
        }
        if case .input(let audioInput) = audioSource {
            await audioInput.stop()
        }
    }

    /// Finalizes the recording exactly once, flushing and closing the file
    /// and reporting `recording.stopped`. A no-op when nothing was recorded.
    private func finalizeRecording() async {
        guard recordingStarted, let recording, let recordingFile else { return }
        recordingStarted = false
        await recording.stop()
        eventBus.event(
            "recording.stopped",
            domain: .output,
            params: ["path": .string(recordingFile.url.path)]
        )
    }

    /// Resolves the session with an outcome exactly once.
    private func finish(_ result: Outcome) {
        guard !finished else { return }
        finished = true
        outcomeContinuation.yield(result)
        outcomeContinuation.finish()
    }

    /// Starts the media pumps: program video (tick-paced) and program audio,
    /// both rebased onto the session timeline before reaching the service.
    ///
    /// The video side is already at the program tick rate before this pump
    /// sees it — an ``VideoSource/input(_:)`` source is paced through
    /// ``ProgramPacer`` here (latest-wins, re-sending across a stall), while a
    /// ``VideoSource/program(_:)`` source arrives already paced by the
    /// compositor and is consumed as-is. The audio side mirrors it: an
    /// ``AudioSource/input(_:)`` source passes through at capture cadence,
    /// while an ``AudioSource/program(_:)`` source arrives already paced by
    /// the mixer's mix tick. All of them stamp media on the master clock, so
    /// the identical `T0` rebase applies.
    ///
    /// Each pump delivers the rebased media to **every** leg's service, in
    /// leg order. The service list is snapshotted here rather than re-read
    /// per frame: legs are fixed for the session, and a leg that is dead or
    /// mid-reconnect discards what it is sent — exactly what a single
    /// destination already did across a reconnect gap — so the hot path
    /// stays free of state reads.
    private func startPumps(t0: CMTime) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        let services = legs.map(\.service)
        if let videoSource {
            let frames: AsyncStream<CapturedFrame>
            switch videoSource {
            case .input(let videoInput):
                frames = ProgramPacer(clock: clock, frameRate: configuration.frameRate)
                    .frames(from: videoInput.frames())
            case .program(let programVideo):
                frames = programVideo
            }
            let recording = self.recording
            tasks.append(
                Task {
                    for await frame in frames {
                        let rebased = CapturedFrame(
                            pixelBuffer: frame.pixelBuffer,
                            presentationTime: CMTimeSubtract(frame.presentationTime, t0)
                        )
                        // The program frame is immutable after it is yielded,
                        // so every compression sink reads the same buffer
                        // within the tick — none mutates it, per the frame
                        // ownership rule (ARCHITECTURE.md).
                        for service in services {
                            await service.send(video: rebased)
                        }
                        await recording?.send(video: rebased)
                    }
                }
            )
        }
        if let audioSource {
            let audio: AsyncStream<CapturedAudio>
            switch audioSource {
            case .input(let audioInput):
                audio = audioInput.audio()
            case .program(let programAudio):
                audio = programAudio
            }
            let recording = self.recording
            tasks.append(
                Task {
                    for await buffer in audio {
                        guard let rebased = buffer.rebased(by: t0) else { continue }
                        for service in services {
                            await service.send(audio: rebased)
                        }
                        await recording?.send(audio: rebased)
                    }
                }
            )
        }
        return tasks
    }

    /// Watches every leg's connection events and drives that leg's reconnect
    /// policy: `stream.reconnecting` per attempt, `stream.reconnected` on
    /// recovery, `stream.destination.lost` when the leg's budget is
    /// exhausted, and ``Outcome/connectionLost`` only once the last live leg
    /// is gone. One watcher per leg, so the legs never share reconnect state.
    private func watchConnections() -> [Task<Void, Never>] {
        legs.indices.map { index in
            let service = legs[index].service
            return Task {
                for await event in service.events {
                    switch event {
                    case .connectionLost(let reason):
                        await reconnect(leg: index, after: reason)
                    }
                }
            }
        }
    }

    /// Watches the recording service's events and reports a write failure.
    ///
    /// A recording failure is auxiliary and terminal: it is reported as an
    /// `error` event (identifier `recordingFailed`) so scripts and the
    /// operator see it, but it never ends the stream — recording is
    /// independent of streaming (CLI.md), so a live stream keeps running
    /// while the recording sink stops. The file is still finalized on
    /// teardown, capturing whatever was written before the failure.
    private func watchRecording() -> Task<Void, Never>? {
        guard let recording else { return nil }
        return Task {
            for await event in recording.events {
                switch event {
                case .failed(let reason):
                    reportRecordingFailure(reason)
                }
            }
        }
    }

    /// Emits the `recordingFailed` error event for a recording write failure,
    /// and ends the session when the failure leaves it with nothing to do.
    ///
    /// The rule that recording never ends a stream is unchanged: a session
    /// with any live destination keeps running, exactly as before. What is
    /// added is the case that rule never had to cover — a **record-only**
    /// session, whose failed file sink was its only one. Left running it
    /// would pump the program into nothing while the operator watches a
    /// control that claims a stopped file is still growing, so it finishes
    /// with ``Outcome/recordingFailed`` (ARCHITECTURE.md, "Recording in the
    /// app").
    private func reportRecordingFailure(_ reason: String) {
        eventBus.error(
            "recording.write",
            domain: .output,
            params: [
                "identifier": .string(ErrorIdentifier.recordingFailed.rawValue),
                "message": .string("The recording stopped and could not continue: \(reason)"),
            ]
        )
        // Only a session with no live leg left has run out of reasons to
        // exist. `recordingStarted` deliberately stays set: teardown still
        // finalizes the file, capturing whatever was written before the
        // failure, exactly as it did before this case existed.
        if liveLegCount == 0 {
            finish(.recordingFailed)
        }
    }

    /// Runs the reconnect attempts for one leg's connection loss.
    ///
    /// The budget and the stability window are the leg's own: a loss within
    /// the stability window of *that leg's* last recovery is the same outage
    /// and keeps draining its budget; a loss after a stable stretch (or its
    /// first loss) gets the policy's full budget. One destination flapping
    /// therefore never spends another destination's attempts.
    ///
    /// When the leg's budget runs out it goes dead and is reported, and the
    /// session ends only if it was the last live one.
    private func reconnect(leg index: Int, after reason: String) async {
        // A leg that was rejected at start, or already lost, has nothing left
        // to reconnect — a late loss event from its service is ignored.
        guard legStates[index].isLive else { return }
        let isSameOutage =
            legStates[index].lastRecoveryTime.map {
                CMTimeSubtract(clock.now, $0).seconds < Double(policy.stabilitySeconds)
            } ?? false
        if !isSameOutage {
            legStates[index].remainingReconnectAttempts = policy.reconnectAttempts
        }
        while legStates[index].remainingReconnectAttempts > 0 {
            guard !finished else { return }
            let attempt = policy.reconnectAttempts - legStates[index].remainingReconnectAttempts + 1
            legStates[index].remainingReconnectAttempts -= 1
            var params = legParams(index)
            params["attempt"] = .int(attempt)
            params["maxAttempts"] = .int(policy.reconnectAttempts)
            params["delay"] = .int(policy.reconnectDelaySeconds)
            params["reason"] = .string(reason)
            eventBus.event("stream.reconnecting", domain: .output, params: params)
            await sleep(seconds: policy.reconnectDelaySeconds)
            guard !finished else { return }
            do {
                try await legs[index].service.start(to: legs[index].destination)
                legStates[index].lastRecoveryTime = clock.now
                var recovered = legParams(index)
                recovered["attempt"] = .int(attempt)
                eventBus.event("stream.reconnected", domain: .output, params: recovered)
                return
            } catch {
                var failed = legParams(index)
                failed["attempt"] = .int(attempt)
                failed["error"] = .string(String(describing: error))
                eventBus.network("stream.reconnect.attempt", domain: .output, params: failed)
            }
        }
        legStates[index].isLive = false
        reportDestinationLost(index, reason: reason)
        // The run survives a partial loss and ends only when nothing is left
        // to stream to (CLI.md, "Multiple destinations").
        if liveLegCount == 0 {
            finish(.connectionLost)
        }
    }

    /// Emits one `stream.stats` per live leg on the policy's cadence, reading
    /// each service's live counters (a point read for a periodic report — the
    /// status-sink model in EVENTS.md, not a poll for state changes).
    ///
    /// One destination emits exactly one line per tick as before, now
    /// carrying its leg identity; N destinations emit N lines, so a consumer
    /// reads each leg's delivery rather than an average that describes none
    /// of them. A dead leg reports nothing.
    private func watchStats(t0: CMTime) -> Task<Void, Never>? {
        guard policy.statsIntervalSeconds > 0 else { return nil }
        let interval = CMTime(value: CMTimeValue(policy.statsIntervalSeconds), timescale: 1)
        return Task {
            for await tickTime in clock.tick(every: interval) {
                await emitStats(at: tickTime, t0: t0)
            }
        }
    }

    /// Emits one tick's `stream.stats` for every live leg.
    ///
    /// - Parameters:
    ///   - tickTime: The stats tick on the master clock.
    ///   - t0: The session start, so `elapsed` is session relative.
    private func emitStats(at tickTime: CMTime, t0: CMTime) async {
        for index in legs.indices where legStates[index].isLive {
            let statistics = await legs[index].service.statistics()
            var params = legParams(index)
            params["elapsed"] = .double(CMTimeSubtract(tickTime, t0).seconds)
            params["bytesSent"] = .int(statistics.bytesSent)
            params["bitrate"] = .int(statistics.bytesPerSecond * 8)
            params["fps"] = .int(statistics.framesPerSecond)
            eventBus.event("stream.stats", domain: .output, params: params)
        }
    }

    /// Ends the session with ``Outcome/durationElapsed`` when the
    /// configured duration passes on the master clock.
    private func watchDuration() -> Task<Void, Never>? {
        guard let durationSeconds = policy.durationSeconds else { return nil }
        return Task {
            await sleep(seconds: durationSeconds)
            finish(.durationElapsed)
        }
    }

    /// Waits the given number of seconds on the session's clock (the
    /// first tick of a one-interval stream), so tests drive every wait
    /// synthetically. Returns immediately for zero seconds.
    private func sleep(seconds: Int) async {
        guard seconds > 0 else { return }
        let interval = CMTime(value: CMTimeValue(seconds), timescale: 1)
        for await _ in clock.tick(every: interval) {
            break
        }
    }

    /// The `stream.started` params: the resolved pipeline, mirroring the
    /// `stream.plan` param names (a stable scripting contract, CLI.md).
    /// The stream key never appears; a disabled side omits its block.
    ///
    /// `url` stays the **first live leg's** URL — identical to the one
    /// destination case, and never a synthesized value — with the additive
    /// `destinations`/`destinationsRejected` counts summarizing the fan-out.
    /// Which legs those are is reported per leg by `stream.destination.started`
    /// and `stream.destination.rejected`, so the flat event contract holds.
    private var startedParams: [String: EventValue] {
        var params: [String: EventValue] = [:]
        if let label { params["session"] = .string(label) }
        if let firstLive = legs.indices.first(where: { legStates[$0].isLive }) {
            params["url"] = .string(legs[firstLive].destination.url.absoluteString)
        }
        params["destinations"] = .int(liveLegCount)
        params["destinationsRejected"] = .int(legs.count - liveLegCount)
        if let videoSource {
            // A single input names itself; the compositor's program has no one
            // device to name, so it reports the stable "program" identity.
            switch videoSource {
            case .input(let videoInput):
                params["videoInput"] = .string(videoInput.id.rawValue)
                params["videoInputName"] = .string(videoInput.name)
            case .program:
                params["videoInput"] = .string("program")
                params["videoInputName"] = .string("Program")
            }
            params["resolution"] = .string("\(configuration.width)x\(configuration.height)")
            params["fps"] = .int(configuration.frameRate)
            params["videoCodec"] = .string(configuration.videoCodec.rawValue)
            params["videoBitrate"] = .int(configuration.videoBitsPerSecond)
            params["keyframeInterval"] = .int(configuration.keyframeInterval)
        }
        if let audioSource {
            // A single input names itself; the mixer's program mix has no one
            // device to name, so it reports the stable "mix" identity
            // (GLOSSARY.md, "Mixer" — every audio input combined into the
            // program mix).
            switch audioSource {
            case .input(let audioInput):
                params["audioInput"] = .string(audioInput.id.rawValue)
                params["audioInputName"] = .string(audioInput.name)
            case .program:
                params["audioInput"] = .string("mix")
                params["audioInputName"] = .string("Mix")
            }
            params["audioCodec"] = .string(configuration.audioCodec.rawValue)
            params["audioBitrate"] = .int(configuration.audioBitsPerSecond)
            params["audioSamplerate"] = .int(configuration.audioSampleRate)
        }
        return params
    }
}
