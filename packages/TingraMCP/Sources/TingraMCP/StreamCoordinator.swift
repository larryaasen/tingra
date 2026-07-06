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

/// The fully resolved inputs to a stream, as the `stream_start` tool parsed
/// and validated them from the MCP arguments before handing them to the
/// coordinator.
struct StreamRequest: Sendable {
    /// The destination URL string (scheme already validated).
    let url: String

    /// The stream key, read from the tool arguments; never logged or returned.
    let streamKey: String?

    /// Which input feeds the video side.
    let video: SideSelection

    /// Which input feeds the audio side.
    let audio: SideSelection

    /// The compression and program settings.
    let configuration: StreamConfiguration

    /// The reconnect/stats/duration policy.
    let policy: StreamSession.Policy
}

/// Owns the one active stream in v1 (CLI.md, "Non-goals (v1)": one
/// destination) on behalf of the `stream_start`/`stream_status`/`stream_stop`
/// tools. It reuses the host's ``StreamSession`` machinery rather than
/// duplicating the pipeline, and keys every operation off the session id
/// `stream_start` returns.
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

        /// The destination URL, for `stream_status`.
        let url: String
    }

    /// The active stream, or nil when nothing is streaming.
    private var active: Active?

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
    /// so the daemon never idle-exits mid-stream (MCP.md, "Idle exit").
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

        let destination = try makeDestination(request)
        let service = try await makeService(request, destination: destination)
        let videoInput = try await resolve(request.video, kind: .camera, defaultID: defaults.cameraID())
        let audioInput = try await resolve(request.audio, kind: .microphone, defaultID: defaults.microphoneID())

        let session = StreamSession(
            videoInput: videoInput,
            audioInput: audioInput,
            service: service,
            destination: destination,
            configuration: request.configuration,
            policy: request.policy,
            clock: clock,
            eventBus: eventBus
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

        do {
            try await gate.wait()
        } catch {
            // Start failed: the run task already finished and cleared nothing
            // (active was never set). Surface the identifier-keyed error.
            throw Self.toolError(from: error)
        }

        active = Active(id: id, session: session, runTask: runTask, url: request.url)
        return id
    }

    /// Reports the current status of the stream with the given id.
    ///
    /// Reads the latest retained `stream.stats` from the status sink — a
    /// point read of live data, never a poll (EVENTS.md, "Status sink").
    /// Throws a ``ToolError`` if the id does not name the active stream.
    func statusReport(sessionId: String) async throws -> JSONValue {
        guard let active, active.id == sessionId else {
            throw unknownSession(sessionId)
        }
        var report: [String: JSONValue] = [
            "sessionId": .string(active.id),
            "state": .string("live"),
            "url": .string(active.url),
        ]
        // The most recent stats sample, if one has been emitted yet (the
        // first arrives one stats interval after start).
        if let stats = await status.latestEvent(named: "stream.stats"), let params = stats.params {
            for key in ["elapsed", "bytesSent", "bitrate", "fps"] where params[key] != nil {
                if let value = params[key] {
                    report[key] = JSONValue(value)
                }
            }
        }
        return .object(report)
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

    /// Clears the active stream once its run task ends (a stop, a duration
    /// elapse, or a start failure). Only clears if the id still matches, so a
    /// late clear from a superseded session cannot wipe a newer one.
    private func clear(id: String) {
        if active?.id == id {
            active = nil
        }
    }

    /// Builds the destination, carrying the stream key inward only.
    private func makeDestination(_ request: StreamRequest) throws -> Destination {
        guard let url = URL(string: request.url) else {
            throw ToolError(identifier: .invalidArgument, message: "The url '\(request.url)' is not a valid URL.")
        }
        return Destination(url: url, streamKey: request.streamKey)
    }

    /// Resolves the destination scheme to a provider and creates a service.
    private func makeService(_ request: StreamRequest, destination: Destination) async throws
        -> any StreamingService
    {
        guard let scheme = destination.url.scheme?.lowercased() else {
            throw ToolError(identifier: .invalidArgument, message: "The url '\(request.url)' has no scheme.")
        }
        guard let provider = await outputs.provider(forScheme: scheme) else {
            throw ToolError(
                identifier: .invalidArgument,
                message:
                    "No registered output serves '\(scheme)://' destinations in v1 — SRT output arrives at "
                    + "roadmap step 8. Stream to an rtmp:// or rtmps:// destination."
            )
        }
        return provider.makeStreamingService(configuration: request.configuration)
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
