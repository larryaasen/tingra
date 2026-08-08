//
//  StreamCoordinator.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// Which input feeds one side (video or audio) of a stream, as the
/// `stream_start` tool resolved it from its arguments. Mirrors the CLI's
/// selection rules (CLI.md, "Input selection").
enum SideSelection: Sendable, Equatable {
    /// The side is off (`--no-video` / `--no-audio`).
    case disabled

    /// A generator stands in for hardware (`--video-generator` / `--audio-generator`).
    case generator(InputID)

    /// An explicit device selector (index, name substring, or ID).
    case device(selector: String)

    /// No selector given: resolve the system default device.
    case systemDefault
}

/// The system default input identifiers, injected so the coordinator never
/// imports the capture package (production passes the capture plug-in's
/// `SystemDefaultInputs`; tests pass stubs).
public struct StreamDefaults: Sendable {
    /// The system default camera's identifier, or nil without a camera.
    public let cameraID: @Sendable () -> InputID?

    /// The system default microphone's identifier, or nil without one.
    public let microphoneID: @Sendable () -> InputID?

    /// Creates a defaults provider.
    ///
    /// - Parameters:
    ///   - cameraID: Resolves the system default camera identifier.
    ///   - microphoneID: Resolves the system default microphone identifier.
    public init(
        cameraID: @escaping @Sendable () -> InputID?,
        microphoneID: @escaping @Sendable () -> InputID?
    ) {
        self.cameraID = cameraID
        self.microphoneID = microphoneID
    }
}

/// One destination a `stream_start` call asked for: where a leg goes, and
/// the key it publishes with.
struct RequestedDestination: Sendable {
    /// The leg's stable identity in the status events and `stream_status`,
    /// minted by position (`destination-1`, `destination-2`, …) so an agent
    /// can tell one leg's numbers from another's.
    let id: String

    /// The destination URL string (scheme already validated).
    let url: String

    /// The stream key, read from the tool arguments; never logged or returned.
    ///
    /// **Transient by policy** (MCP.md, "Sessions and concurrency"): the
    /// daemon holds a key only for the life of the session it starts and
    /// never writes it to secure storage, so it outlives neither the session
    /// nor the process. The value lives here and in the leg's `Destination`
    /// for the duration, and both are released together when
    /// ``StreamCoordinator/clear(id:)`` drops the active session. Persisting
    /// a key belongs to the destination model, not to the daemon — the app
    /// persists because a saved destination is a document with an owner,
    /// while this caller already holds the key it is passing.
    let streamKey: String?
}

/// The local recording a `stream_start` call asked for with its `record`
/// field: where the file goes, already expanded and validated by the tool.
///
/// The path is the caller's, verbatim (MCP.md, "Tool surface"): the daemon
/// adds no filename policy, no date stamp, and no overwrite protection
/// beyond the recording service's own. A recording path is not a secret and
/// appears as-is in events and status.
struct RequestedRecording: Sendable, Equatable {
    /// The expanded, absolute file URL the recording writes to.
    let url: URL

    /// The lowercased path extension, which selects the container and the
    /// recording provider (`mov`/`mp4`) — the same resolution the CLI's
    /// `--record` uses.
    let fileExtension: String
}

/// The fully resolved inputs to a stream, as the `stream_start` tool parsed
/// and validated them from the MCP arguments before handing them to the
/// coordinator.
struct StreamRequest: Sendable {
    /// The destinations the one program fans out to, in the order requested.
    /// One session, N legs — the "one active stream" rule is unchanged
    /// (MCP.md, "Sessions and concurrency"). **Empty is legal when
    /// ``recording`` is present**: a record-only session, the engine shape
    /// "Recording in the app" made legal (ARCHITECTURE.md); the tool refuses
    /// a request with neither.
    let destinations: [RequestedDestination]

    /// The local recording the session writes alongside (or instead of)
    /// streaming, or nil when `record` was not given.
    let recording: RequestedRecording?

    /// Which input feeds the video side.
    let video: SideSelection

    /// Which input feeds the audio side.
    let audio: SideSelection

    /// The compression and program settings.
    let configuration: StreamConfiguration

    /// The reconnect/stats/duration policy.
    let policy: StreamSession.Policy
}

/// Owns the one active stream on behalf of the
/// `stream_start`/`stream_status`/`stream_stop` tools. It reuses the host's
/// ``StreamSession`` machinery rather than duplicating the pipeline, and keys
/// every operation off the session id `stream_start` returns.
///
/// "One active stream" means **one session, N destination legs**: a
/// `stream_start` naming several destinations still returns one id, and
/// `stream_status` reports each leg under it. Concurrent *sessions* remain
/// out of scope — they would break both this coordinator and the daemon's
/// idle-exit guard (MCP.md, "Sessions and concurrency").
///
/// The coordinator confirms a stream is *live* before `stream_start` returns
/// — it watches the event bus for `stream.started` (success) or the session's
/// start-time throw (failure) — so the agent gets an immediate, actionable
/// result rather than a fire-and-forget id.
public actor StreamCoordinator {
    /// The bookkeeping for the one active stream.
    private struct Active {
        /// The session id handed back to the agent.
        let id: String

        /// The running session.
        let session: StreamSession

        /// The task pumping the session until it ends.
        let runTask: Task<Void, Never>

        /// The destinations the session fans out to, for `stream_status`.
        ///
        /// This is the only thing holding each leg's stream key while the
        /// session runs, so clearing `active` is what makes the daemon's
        /// transient-key policy true — see
        /// ``RequestedDestination/streamKey`` and ``clear(id:)``.
        let destinations: [RequestedDestination]

        /// Where the session's recording is written, or nil when none was
        /// requested — what `stream_status`'s `recording` object reports
        /// while the session's recording is open.
        let recordingFile: RecordingFile?
    }

    /// The active stream, or nil when nothing is streaming.
    private var active: Active?

    /// Whether a `start` is between its conflict check and installing
    /// ``active``.
    ///
    /// The conflict check reads `active`, but resolving the destinations and
    /// inputs immediately after it suspends. Without this flag two concurrent
    /// `stream_start` calls both pass the check while `active` is still nil,
    /// both build a session, and both install — the second overwriting the
    /// first, whose destinations keep publishing under an id that no longer
    /// resolves to anything, so it can never be stopped and its stream key is
    /// never released. Claimed synchronously right after the check and
    /// released in a `defer`, so the "one active stream" rule (MCP.md,
    /// "Sessions and concurrency") covers the whole of startup rather than
    /// only its tail.
    private var startInProgress = false

    /// The input registry inputs resolve against.
    private let inputs: InputRegistry

    /// The output registry that resolves a destination scheme to a provider.
    private let outputs: OutputRegistry

    /// The status sink `stream_status` reads live counters from.
    private let status: StatusSink

    /// The event bus carrying the session's status events.
    private let eventBus: EventBus

    /// The master clock the session paces on (synthetic in tests).
    private let clock: any EngineClock

    /// The system default input provider.
    private let defaults: StreamDefaults

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - inputs: The input registry.
    ///   - outputs: The output registry.
    ///   - status: The status sink for `stream_status`.
    ///   - eventBus: The event bus.
    ///   - clock: The master clock (synthetic in tests).
    ///   - defaults: The system default input provider.
    public init(
        inputs: InputRegistry,
        outputs: OutputRegistry,
        status: StatusSink,
        eventBus: EventBus,
        clock: any EngineClock,
        defaults: StreamDefaults
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.status = status
        self.eventBus = eventBus
        self.clock = clock
        self.defaults = defaults
    }

    /// Whether a stream is currently active — the idle-exit guard reads this
    /// so the daemon never idle-exits mid-stream (MCP.md, "Idle exit"). A
    /// record-only session counts: the guard's promise is "nothing streaming
    /// **or recording**", and a session is a session whether its sinks are
    /// destinations, a file, or both.
    public var isStreaming: Bool { active != nil }

    /// Starts a stream and returns its session id once media is flowing.
    ///
    /// Throws a ``ToolError`` for a conflicting start (one active stream in
    /// v1), an unresolvable input or destination, a denied authorization, or
    /// a rejected connection — every failure carries a stable identifier.
    func start(_ request: StreamRequest) async throws -> String {
        if let active {
            throw ToolError(
                identifier: .invalidArgument,
                message:
                    "A stream is already active (session '\(active.id)'). Stop it with stream_stop "
                    + "before starting another — v1 supports one active stream."
            )
        }
        if startInProgress {
            throw ToolError(
                identifier: .invalidArgument,
                message:
                    "A stream is already starting. Wait for that stream_start to return — it reports "
                    + "the session id once the stream is live — then use stream_stop before starting "
                    + "another; v1 supports one active stream."
            )
        }
        // Claimed synchronously, before the first suspension below, so a
        // concurrent call cannot slip past both checks while this one is
        // still resolving its destinations and inputs.
        startInProgress = true
        defer { startInProgress = false }

        let legs = try await makeDestinationLegs(request)
        let (recordingService, recordingFile) = try await makeRecording(request)
        let videoInput = try await resolve(request.video, kind: .camera, defaultID: defaults.cameraID())
        let audioInput = try await resolve(request.audio, kind: .microphone, defaultID: defaults.microphoneID())

        let session = StreamSession(
            videoInput: videoInput,
            audioInput: audioInput,
            destinations: legs,
            configuration: request.configuration,
            policy: request.policy,
            clock: clock,
            eventBus: eventBus,
            recording: recordingService,
            recordingFile: recordingFile
        )
        let id = "stream-" + UUID().uuidString.prefix(8).lowercased()

        // Confirm the stream reaches "live" before returning: `run()` throws
        // for start-time failures (before `stream.started`), and emits
        // `stream.started` on success. Subscribe to the bus first so the
        // event cannot be missed, then race the two outcomes through a gate.
        let gate = StartGate()
        let events = eventBus.events()
        let watch = Task {
            for await event in events where event.name == "stream.started" {
                await gate.succeed()
                break
            }
        }
        defer { watch.cancel() }

        let runTask = Task { [weak self] in
            do {
                _ = try await session.run()
            } catch {
                await gate.fail(error)
            }
            await self?.clear(id: id)
        }

        // Install *before* awaiting the gate, not after. `clear(id:)` runs
        // from the run task and can land during that suspension: a session
        // that ends between emitting `stream.started` and this waiter
        // resuming would be cleared before it was ever installed, so the
        // clear would no-op on a nil `active` and the install would then
        // resurrect a dead session — retaining its stream key for the life
        // of the daemon (contradicting the transient-key policy), refusing
        // every later `stream_start` as a conflict with a session that is
        // over, and pinning `isStreaming` true so the idle-exit guard never
        // fires. There is no suspension point between the run task's
        // creation and this line, so the run task cannot reach the actor
        // before the install — which is what closes the window rather than
        // merely narrowing it.
        active = Active(
            id: id, session: session, runTask: runTask, destinations: request.destinations,
            recordingFile: recordingFile)

        do {
            try await gate.wait()
        } catch {
            // Start failed. The run task's own `clear` may or may not have
            // landed yet, so drop it here too — both are id-matched, so
            // whichever runs second is a no-op.
            clear(id: id)
            throw Self.toolError(from: error)
        }

        // A session that went live and ended within this window is already
        // cleared, and deliberately stays that way: `stream_status` and
        // `stream_stop` on the returned id report an unknown session, which
        // is the defined answer for a session that is not active, and the
        // `stream.stopped` event on the bus carries the reason.
        return id
    }

    /// Reports the current status of the stream with the given id.
    ///
    /// Reads each destination's latest retained `stream.stats` from the
    /// status sink — a point read of live data, never a poll (EVENTS.md,
    /// "Status sink"). A fanned-out stream reports every leg under
    /// `destinations`; the flat top-level counters stay the **first**
    /// destination's, so a caller written against one destination reads the
    /// same fields and never a synthesized average. A session with a
    /// recording reports it under `recording` while the file is open —
    /// absent once it has finalized or failed, the same absence contract a
    /// rejected leg has (MCP.md, "Tool surface").
    ///
    /// Throws a ``ToolError`` if the id does not name the active stream.
    func statusReport(sessionId: String) async throws -> JSONValue {
        guard let active, active.id == sessionId else {
            throw unknownSession(sessionId)
        }
        var report: [String: JSONValue] = [
            "sessionId": .string(active.id),
            "state": .string("live"),
        ]
        if let first = active.destinations.first {
            report["url"] = .string(first.url)
        }
        if let file = active.recordingFile, await active.session.isRecordingOpen {
            report["recording"] = .object([
                "path": .string(file.url.path),
                "container": .string(file.container.rawValue),
            ])
        }

        var legs: [JSONValue] = []
        for destination in active.destinations {
            var leg: [String: JSONValue] = [
                "destination": .string(destination.id),
                "url": .string(destination.url),
            ]
            // A leg reports counters once it has emitted a stats sample; a
            // leg rejected at start or already lost simply has none.
            let stats = await status.latestEvent(named: "stream.stats", forDestination: destination.id)
            Self.copyStatsFields(from: stats, into: &leg)
            leg["state"] = .string(stats == nil ? "pending" : "live")
            legs.append(.object(leg))

            if destination.id == active.destinations.first?.id {
                Self.copyStatsFields(from: stats, into: &report)
            }
        }
        report["destinations"] = .array(legs)
        return .object(report)
    }

    /// Copies the delivery counters out of a `stream.stats` event into a
    /// status report object. A nil event copies nothing (no sample yet).
    ///
    /// - Parameters:
    ///   - stats: The retained `stream.stats` event, if one has arrived.
    ///   - report: The report object to fill in.
    private static func copyStatsFields(from stats: EventBusEvent?, into report: inout [String: JSONValue]) {
        guard let params = stats?.params else { return }
        for key in ["elapsed", "bytesSent", "bitrate", "fps"] {
            if let value = params[key] {
                report[key] = JSONValue(value)
            }
        }
    }

    /// Stops the stream with the given id: a clean stop that flushes
    /// compression and closes the connection, awaiting an orderly teardown.
    ///
    /// Throws a ``ToolError`` if the id does not name the active stream.
    func stop(sessionId: String) async throws -> JSONValue {
        guard let active, active.id == sessionId else {
            throw unknownSession(sessionId)
        }
        await active.session.stop()
        await active.runTask.value  // Wait for the orderly teardown to finish.
        return .object([
            "sessionId": .string(sessionId),
            "stopped": .bool(true),
        ])
    }

    /// Waits for a session to end and its state to be released, without
    /// stopping it.
    ///
    /// A seam for the teardown paths that are *not* an explicit
    /// `stream_stop` — a duration elapse and a lost connection. Those end the
    /// session from inside its own run task, which clears the coordinator one
    /// actor hop **after** `stream.stopped` reaches the event bus, so an
    /// observer that awaits the event alone cannot know the release has
    /// happened. Awaiting the run task closes that gap, because
    /// ``clear(id:)`` runs inside it — the same guarantee
    /// ``stop(sessionId:)`` already relies on.
    ///
    /// Returns immediately when the id is not the active session, which is
    /// the already-ended case rather than an error.
    ///
    /// - Parameter sessionId: The session to wait for.
    func waitForEnd(sessionId: String) async {
        guard let active, active.id == sessionId else { return }
        await active.runTask.value
    }

    /// Clears the active stream once its run task ends (a stop, a duration
    /// elapse, a lost connection, or a start failure). Only clears if the id
    /// still matches, so a late clear from a superseded session cannot wipe a
    /// newer one.
    ///
    /// This is also where the session's stream keys go: they are held only in
    /// `Active.destinations`, so dropping it is what enforces the daemon's
    /// transient-key policy on *every* teardown path rather than only on an
    /// explicit `stream_stop` (MCP.md, "Sessions and concurrency").
    private func clear(id: String) {
        if active?.id == id {
            active = nil
        }
    }

    /// Builds one destination leg per requested destination, each with its
    /// own streaming service and its own stream key.
    ///
    /// Every leg's scheme resolves independently against the one output
    /// registry, so a request can mix transports (RTMP beside SRT). The keys
    /// travel inward only — never into a status report, an event, or a log.
    ///
    /// - Parameter request: The parsed `stream_start` request.
    /// - Returns: The legs, in the requested order.
    /// - Throws: A ``ToolError`` with `invalidArgument` for a URL that does
    ///   not parse or resolves to no registered output.
    private func makeDestinationLegs(_ request: StreamRequest) async throws -> [StreamSession.DestinationLeg] {
        var legs: [StreamSession.DestinationLeg] = []
        for destination in request.destinations {
            guard let url = URL(string: destination.url) else {
                throw ToolError(
                    identifier: .invalidArgument,
                    message: "The url '\(destination.url)' is not a valid URL."
                )
            }
            guard let scheme = url.scheme?.lowercased() else {
                throw ToolError(identifier: .invalidArgument, message: "The url '\(destination.url)' has no scheme.")
            }
            guard let provider = await outputs.provider(forScheme: scheme) else {
                throw ToolError(
                    identifier: .invalidArgument,
                    message:
                        "No registered output serves '\(scheme)://' destinations. Stream to an rtmp://, "
                        + "rtmps://, or srt:// destination."
                )
            }
            legs.append(
                StreamSession.DestinationLeg(
                    id: destination.id,
                    destination: Destination(url: url, streamKey: destination.streamKey),
                    service: provider.makeStreamingService(configuration: request.configuration)
                )
            )
        }
        return legs
    }

    /// Resolves the requested recording to its service and file, or
    /// `(nil, nil)` when the request has none.
    ///
    /// The file extension resolves against the same output registry the
    /// streaming providers live in — recording is a plug-in like everything
    /// else, and this is the same resolution the CLI's `--record` uses. A
    /// registry with no provider for the extension is a `recordingFailed`
    /// tool error, the analog of the CLI's exit-70-at-setup.
    ///
    /// - Parameter request: The parsed `stream_start` request.
    /// - Returns: The recording service and its file, or `(nil, nil)`.
    /// - Throws: A ``ToolError`` with `recordingFailed` when no recording
    ///   output serves the extension.
    private func makeRecording(_ request: StreamRequest) async throws
        -> (service: (any RecordingService)?, file: RecordingFile?)
    {
        guard let recording = request.recording else { return (nil, nil) }
        guard let provider = await outputs.recordingProvider(forFileExtension: recording.fileExtension) else {
            throw ToolError(
                identifier: .recordingFailed,
                message:
                    "No recording output serves '.\(recording.fileExtension)' files; record to a .mov "
                    + "or .mp4 path."
            )
        }
        let container: RecordingFile.Container = recording.fileExtension == "mp4" ? .mp4 : .mov
        let file = RecordingFile(url: recording.url, container: container)
        return (provider.makeRecordingService(configuration: request.configuration), file)
    }

    /// Resolves one side of the pipeline to an input, mapping selector
    /// failures to identifier-keyed tool errors.
    private func resolve(_ side: SideSelection, kind: InputKind, defaultID: InputID?) async throws
        -> (any Input)?
    {
        do {
            switch side {
            case .disabled:
                return nil
            case .generator(let id):
                return try await inputs.resolveInput(selector: id.rawValue, ofKind: .generator)
            case .device(let selector):
                return try await inputs.resolveInput(selector: selector, ofKind: kind)
            case .systemDefault:
                guard let defaultID else {
                    throw ToolError(
                        identifier: .inputNotFound,
                        message:
                            "No \(kind.rawValue) is connected to default to. Connect one, pass a selector, or "
                            + "use a generator to stream without hardware."
                    )
                }
                return try await inputs.resolveInput(selector: defaultID.rawValue, ofKind: kind)
            }
        } catch let toolError as ToolError {
            throw toolError
        } catch {
            throw Self.toolError(from: error)
        }
    }

    /// The tool error for an id that does not name the active stream.
    private func unknownSession(_ sessionId: String) -> ToolError {
        let current = active.map { "the active stream is '\($0.id)'" } ?? "no stream is active"
        return ToolError(
            identifier: .invalidArgument,
            message: "No active stream has the id '\(sessionId)' (\(current))."
        )
    }

    /// Maps any engine error to an identifier-keyed tool error: an
    /// ``IdentifiedError`` keeps its identifier; anything else is a pipeline
    /// error.
    static func toolError(from error: any Error) -> ToolError {
        if let identified = error as? any IdentifiedError {
            return ToolError(identifier: identified.identifier, message: String(describing: error))
        }
        if let toolError = error as? ToolError {
            return toolError
        }
        return ToolError(identifier: .pipelineError, message: String(describing: error))
    }
}

/// A one-shot gate resolved by whichever of two racing outcomes happens
/// first — a `stream.started` event (success) or the session's start-time
/// throw (failure) — so `stream_start` can confirm the stream went live.
///
/// An actor, so the check-then-suspend in ``wait()`` and the resolutions in
/// ``succeed()``/``fail(_:)`` never race; only the first resolution wins.
private actor StartGate {
    /// The settled outcome, once one side has resolved the gate.
    private var settled: Result<Void, any Error>?

    /// The waiter suspended in ``wait()``, if it arrived before resolution.
    private var continuation: CheckedContinuation<Void, any Error>?

    /// Suspends until the gate is resolved, returning on success or throwing
    /// the start failure.
    func wait() async throws {
        if let settled {
            return try settled.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Resolves the gate as a successful start.
    func succeed() {
        settle(.success(()))
    }

    /// Resolves the gate as a start failure carrying `error`.
    func fail(_ error: any Error) {
        settle(.failure(error))
    }

    /// Applies the first resolution and resumes any waiter.
    private func settle(_ result: Result<Void, any Error>) {
        guard settled == nil else { return }
        settled = result
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
