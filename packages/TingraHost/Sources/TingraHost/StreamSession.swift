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
/// one video source and one audio input feeding one streaming service (see
/// CLI.md, "Non-goals (v1)": one camera, one microphone, one destination).
///
/// The session owns the shared timeline (`T0` at start; every buffer is
/// rebased onto it before reaching the service, per CLOCK.md "Timestamp
/// rules"), passes audio through at capture cadence, reports the CLI.md
/// status events (`stream.started`, `stream.stats`, `stream.reconnecting`,
/// `stream.reconnected`, `stream.stopped`) on the event bus as `event`-group
/// events in the `output` domain, and drives the reconnect policy when the
/// service reports a connection loss.
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
/// Either way the reconnect machinery, the stability window, the periodic
/// stats, the duration timer, and the pass-through audio path are identical —
/// the app reuses the proven CLI streaming lifecycle rather than rebuilding
/// it (ARCHITECTURE.md, "Streaming the program").
///
/// `tingra-cli stream` drives an ``VideoSource/input(_:)`` session directly;
/// the `serve` daemon owns one per `stream_start` tool call; the phase-3 app
/// drives a ``VideoSource/program(_:)`` session from the compositor.
public actor StreamSession {
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
    }

    /// How the program video is produced, or nil under `--no-video`.
    private let videoSource: VideoSource?

    /// The audio input feeding the program, or nil under `--no-audio`.
    private let audioInput: (any Input)?

    /// The streaming service delivering the program to the destination.
    private let service: any StreamingService

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

    /// Where the program streams to. Held for reconnects; its stream key
    /// never reaches the bus.
    private let destination: Destination

    /// The session's compression and program settings.
    private let configuration: StreamConfiguration

    /// The reconnect/stats/duration policy.
    private let policy: Policy

    /// The master clock: `T0`, the program tick, and every pacing wait
    /// come from it (synthetic in tests).
    private let clock: any EngineClock

    /// The host's event bus, carrying the session's status events.
    private let eventBus: EventBus

    /// The session's finished signal: ``finish(_:)`` yields exactly one
    /// outcome and ``run()`` awaits it.
    private let outcome: AsyncStream<Outcome>
    /// The continuation ``finish(_:)`` resolves the session through.
    private let outcomeContinuation: AsyncStream<Outcome>.Continuation

    /// Whether the session has already finished, so a duplicate trigger
    /// (a signal racing the duration timer) cannot double-finish.
    private var finished = false

    /// When the last successful reconnect happened on the master clock —
    /// how the next loss is classified as the same outage (within the
    /// policy's stability window) or a fresh one.
    private var lastRecoveryTime: CMTime?

    /// The reconnect attempts left for the current outage.
    private var remainingReconnectAttempts = 0

    /// Creates a session from a single capture input (the CLI's one-camera
    /// pipeline). At least one media side should be present; the caller has
    /// already resolved inputs and read the stream key.
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
            audioInput: audioInput,
            service: service,
            destination: destination,
            configuration: configuration,
            policy: policy,
            clock: clock,
            eventBus: eventBus,
            recording: recording,
            recordingFile: recordingFile
        )
    }

    /// Creates a session from an already tick-paced program-frame stream (the
    /// app's compositor path). The caller owns the compositor and its inputs;
    /// the session paces nothing on the video side and starts/stops no video
    /// device — it rebases each program frame onto `T0` and delivers it, while
    /// still owning the audio input's lifecycle.
    ///
    /// - Parameters:
    ///   - programVideo: The compositor's program-frame stream, or nil for an
    ///     audio-only stream.
    ///   - audioInput: The audio input, or nil for a video-only stream.
    ///   - service: The streaming service.
    ///   - destination: Where the program streams to.
    ///   - configuration: The compression and program settings.
    ///   - policy: The reconnect/stats/duration policy.
    ///   - clock: The master clock (the same one pacing the compositor).
    ///   - eventBus: The host's event bus.
    ///   - recording: The recording service, or nil for a stream-only session.
    ///   - recordingFile: Where the recording is written; required when
    ///     `recording` is present, ignored otherwise.
    public init(
        programVideo: AsyncStream<CapturedFrame>?,
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
            videoSource: programVideo.map(VideoSource.program),
            audioInput: audioInput,
            service: service,
            destination: destination,
            configuration: configuration,
            policy: policy,
            clock: clock,
            eventBus: eventBus,
            recording: recording,
            recordingFile: recordingFile
        )
    }

    /// The designated initializer both public inits funnel through.
    ///
    /// - Parameters:
    ///   - videoSource: How the program video is produced, or nil under
    ///     `--no-video`.
    ///   - audioInput: The audio input, or nil for a video-only stream.
    ///   - service: The streaming service.
    ///   - destination: Where the program streams to.
    ///   - configuration: The compression and program settings.
    ///   - policy: The reconnect/stats/duration policy.
    ///   - clock: The master clock (synthetic in tests).
    ///   - eventBus: The host's event bus.
    ///   - recording: The recording service, or nil for a stream-only session.
    ///   - recordingFile: Where the recording is written; required when
    ///     `recording` is present, ignored otherwise.
    private init(
        videoSource: VideoSource?,
        audioInput: (any Input)?,
        service: any StreamingService,
        destination: Destination,
        configuration: StreamConfiguration,
        policy: Policy,
        clock: any EngineClock,
        eventBus: EventBus,
        recording: (any RecordingService)?,
        recordingFile: RecordingFile?
    ) {
        self.videoSource = videoSource
        self.audioInput = audioInput
        self.service = service
        self.destination = destination
        self.configuration = configuration
        self.policy = policy
        self.clock = clock
        self.eventBus = eventBus
        self.recording = recording
        self.recordingFile = recordingFile
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
    /// (authorization denied, device gone) or a rejected initial
    /// connection — so the caller can map them to error identifiers. Once
    /// live, problems surface as events and an eventual outcome, never a
    /// throw.
    public func run() async throws -> Outcome {
        // Only a session-owned capture input is started here; a program-frame
        // source is driven by the caller's compositor, already running.
        if case .input(let videoInput) = videoSource {
            try await videoInput.start()
        }
        if let audioInput {
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
            try await service.start(to: destination)
        } catch {
            await finalizeRecording()
            await stopInputs()
            throw error
        }

        // The shared session start on the master clock: every sink sees
        // PTS = hostTime − T0 from here on (CLOCK.md, Timestamp rules).
        let t0 = clock.now
        eventBus.event("stream.started", domain: .output, params: startedParams)

        let pumpTasks = startPumps(t0: t0)
        let watchTasks = [watchConnection(), watchStats(t0: t0), watchDuration(), watchRecording()]

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
        await service.stop()
        // Finalize the recording last so it captures everything the pumps
        // delivered, however the session ended (stop, duration, or a lost
        // connection).
        await finalizeRecording()
        eventBus.event(
            "stream.stopped",
            domain: .output,
            params: ["reason": .string(result.rawValue)]
        )
        return result
    }

    /// Stops the session-owned inputs, if present. A program-frame video
    /// source is left alone — its compositor and inputs belong to the caller.
    private func stopInputs() async {
        if case .input(let videoInput) = videoSource {
            await videoInput.stop()
        }
        if let audioInput {
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

    /// Starts the media pumps: program video (tick-paced), capture-cadence
    /// audio, both rebased onto the session timeline before reaching the
    /// service.
    ///
    /// The video side is already at the program tick rate before this pump
    /// sees it — an ``VideoSource/input(_:)`` source is paced through
    /// ``ProgramPacer`` here (latest-wins, re-sending across a stall), while a
    /// ``VideoSource/program(_:)`` source arrives already paced by the
    /// compositor and is consumed as-is. Both stamp frames on the master
    /// clock, so the identical `T0` rebase applies.
    private func startPumps(t0: CMTime) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        if let videoSource {
            let frames: AsyncStream<CapturedFrame>
            switch videoSource {
            case .input(let videoInput):
                frames = ProgramPacer(clock: clock, frameRate: configuration.frameRate)
                    .frames(from: videoInput.frames())
            case .program(let programVideo):
                frames = programVideo
            }
            let service = self.service
            let recording = self.recording
            tasks.append(
                Task {
                    for await frame in frames {
                        let rebased = CapturedFrame(
                            pixelBuffer: frame.pixelBuffer,
                            presentationTime: CMTimeSubtract(frame.presentationTime, t0)
                        )
                        // The program frame is immutable after it is yielded,
                        // so both compression sinks read the same buffer
                        // within the tick — neither mutates it, per the frame
                        // ownership rule (ARCHITECTURE.md).
                        await service.send(video: rebased)
                        await recording?.send(video: rebased)
                    }
                }
            )
        }
        if let audioInput {
            let service = self.service
            let recording = self.recording
            tasks.append(
                Task {
                    for await audio in audioInput.audio() {
                        guard let rebased = audio.rebased(by: t0) else { continue }
                        await service.send(audio: rebased)
                        await recording?.send(audio: rebased)
                    }
                }
            )
        }
        return tasks
    }

    /// Watches the service's connection events and drives the reconnect
    /// policy: `stream.reconnecting` per attempt, `stream.reconnected` on
    /// recovery, ``Outcome/connectionLost`` when the budget is exhausted.
    private func watchConnection() -> Task<Void, Never>? {
        Task {
            for await event in service.events {
                switch event {
                case .connectionLost(let reason):
                    await reconnect(after: reason)
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

    /// Emits the `recordingFailed` error event for a recording write failure.
    private func reportRecordingFailure(_ reason: String) {
        eventBus.error(
            "recording.write",
            domain: .output,
            params: [
                "identifier": .string(ErrorIdentifier.recordingFailed.rawValue),
                "message": .string("The recording stopped and could not continue: \(reason)"),
            ]
        )
    }

    /// Runs the reconnect attempts for one connection loss.
    ///
    /// A loss within the stability window of the last recovery is the
    /// same outage and keeps draining the attempt budget; a loss after a
    /// stable stretch (or the first loss) gets the policy's full budget.
    private func reconnect(after reason: String) async {
        let isSameOutage =
            lastRecoveryTime.map {
                CMTimeSubtract(clock.now, $0).seconds < Double(policy.stabilitySeconds)
            } ?? false
        if !isSameOutage {
            remainingReconnectAttempts = policy.reconnectAttempts
        }
        while remainingReconnectAttempts > 0 {
            guard !finished else { return }
            let attempt = policy.reconnectAttempts - remainingReconnectAttempts + 1
            remainingReconnectAttempts -= 1
            eventBus.event(
                "stream.reconnecting",
                domain: .output,
                params: [
                    "attempt": .int(attempt),
                    "maxAttempts": .int(policy.reconnectAttempts),
                    "delay": .int(policy.reconnectDelaySeconds),
                    "reason": .string(reason),
                ]
            )
            await sleep(seconds: policy.reconnectDelaySeconds)
            guard !finished else { return }
            do {
                try await service.start(to: destination)
                lastRecoveryTime = clock.now
                eventBus.event(
                    "stream.reconnected",
                    domain: .output,
                    params: ["attempt": .int(attempt)]
                )
                return
            } catch {
                eventBus.network(
                    "stream.reconnect.attempt",
                    domain: .output,
                    params: [
                        "attempt": .int(attempt),
                        "error": .string(String(describing: error)),
                    ]
                )
            }
        }
        finish(.connectionLost)
    }

    /// Emits `stream.stats` on the policy's cadence, reading the service's
    /// live counters (a point read for a periodic report — the status-sink
    /// model in EVENTS.md, not a poll for state changes).
    private func watchStats(t0: CMTime) -> Task<Void, Never>? {
        guard policy.statsIntervalSeconds > 0 else { return nil }
        let interval = CMTime(value: CMTimeValue(policy.statsIntervalSeconds), timescale: 1)
        return Task {
            for await tickTime in clock.tick(every: interval) {
                let statistics = await service.statistics()
                eventBus.event(
                    "stream.stats",
                    domain: .output,
                    params: [
                        "elapsed": .double(CMTimeSubtract(tickTime, t0).seconds),
                        "bytesSent": .int(statistics.bytesSent),
                        "bitrate": .int(statistics.bytesPerSecond * 8),
                        "fps": .int(statistics.framesPerSecond),
                    ]
                )
            }
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
    private var startedParams: [String: EventValue] {
        var params: [String: EventValue] = [
            "url": .string(destination.url.absoluteString)
        ]
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
        if let audioInput {
            params["audioInput"] = .string(audioInput.id.rawValue)
            params["audioInputName"] = .string(audioInput.name)
            params["audioCodec"] = .string(configuration.audioCodec.rawValue)
            params["audioBitrate"] = .int(configuration.audioBitsPerSecond)
            params["audioSamplerate"] = .int(configuration.audioSampleRate)
        }
        return params
    }
}
