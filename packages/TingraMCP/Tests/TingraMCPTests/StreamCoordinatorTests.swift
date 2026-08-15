//
//  StreamCoordinatorTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraMCP

/// The coordinator that owns the one active stream: start confirms the stream
/// went live, a conflicting start is refused, and status/stop key off the
/// session id — all with mocks, no network.
@Suite("StreamCoordinator")
struct StreamCoordinatorTests {
    /// Builds a coordinator over a registry holding the `bars`/`tone`
    /// generators and a mock RTMP provider, returning the mock service too.
    private func makeCoordinator(
        startError: StreamingServiceError? = nil
    ) async throws -> (StreamCoordinator, MockStreamingService, EventBus) {
        let eventBus = EventBus()
        let inputs = InputRegistry()
        try await inputs.register(StubInput(id: "bars", name: "SMPTE Bars", kind: .generator))
        try await inputs.register(StubInput(id: "tone", name: "440 Hz Tone", kind: .generator))
        let outputs = OutputRegistry()
        let service = MockStreamingService(startError: startError)
        try await outputs.register(MockProvider(service: service))
        let status = StatusSink()
        let coordinator = StreamCoordinator(
            inputs: inputs,
            outputs: outputs,
            status: status,
            eventBus: eventBus,
            clock: FinishingClock(),
            defaults: StreamDefaults(cameraID: { nil }, microphoneID: { nil })
        )
        return (coordinator, service, eventBus)
    }

    /// Builds a coordinator whose registry also holds a mock recording
    /// provider, returning the mock recording service the coordinator will
    /// drive — so no recording test touches a disk or an encoder.
    private func makeRecordingCoordinator(
        recordingStartError: RecordingServiceError? = nil
    ) async throws -> (StreamCoordinator, MockRecordingService, MockStreamingService) {
        let eventBus = EventBus()
        let inputs = InputRegistry()
        try await inputs.register(StubInput(id: "bars", name: "SMPTE Bars", kind: .generator))
        try await inputs.register(StubInput(id: "tone", name: "440 Hz Tone", kind: .generator))
        let outputs = OutputRegistry()
        let service = MockStreamingService()
        try await outputs.register(MockProvider(service: service))
        let recording = MockRecordingService(startError: recordingStartError)
        try await outputs.register(MockRecordingProvider(service: recording))
        let coordinator = StreamCoordinator(
            inputs: inputs,
            outputs: outputs,
            status: StatusSink(),
            eventBus: eventBus,
            clock: FinishingClock(),
            defaults: StreamDefaults(cameraID: { nil }, microphoneID: { nil })
        )
        return (coordinator, recording, service)
    }

    /// The recording every recording request in this suite writes to. The
    /// mock service never touches the path.
    private var requestedRecording: RequestedRecording {
        RequestedRecording(url: URL(filePath: "/Movies/show.mp4"), fileExtension: "mp4")
    }

    /// A generator request that records alongside its one destination.
    private var recordAlongsideRequest: StreamRequest {
        StreamRequest(
            destinations: [
                RequestedDestination(id: "destination-1", url: "rtmp://localhost/live", streamKey: "test_key")
            ],
            recording: requestedRecording,
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
    }

    /// A record-only request: a recording and no destination at all
    /// (MCP.md, "Sessions and concurrency").
    private var recordOnlyRequest: StreamRequest {
        StreamRequest(
            destinations: [],
            recording: requestedRecording,
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
    }

    /// A generator-only request to the mock destination.
    private var generatorRequest: StreamRequest {
        StreamRequest(
            destinations: [
                RequestedDestination(id: "destination-1", url: "rtmp://localhost/live", streamKey: "test_key")
            ],
            recording: nil,
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
    }

    /// A generator-only request fanned out to two mock destinations — one
    /// session with two legs, so a report can hold legs in different states.
    private var twoDestinationRequest: StreamRequest {
        StreamRequest(
            destinations: [
                RequestedDestination(id: "destination-1", url: "rtmp://localhost/live", streamKey: "a"),
                RequestedDestination(id: "destination-2", url: "rtmp://localhost/backup", streamKey: "b"),
            ],
            recording: nil,
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
    }

    /// A request that ends itself once its duration elapses — which the
    /// finishing clock does at once, so the duration teardown path runs
    /// without any wall-clock wait.
    private var durationLimitedRequest: StreamRequest {
        StreamRequest(
            destinations: [
                RequestedDestination(id: "destination-1", url: "rtmp://localhost/live", streamKey: "test_key")
            ],
            recording: nil,
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0, durationSeconds: 1)
        )
    }

    /// A request with reconnect disabled, so a single reported connection
    /// loss ends the session instead of starting a reconnect cycle.
    private var noReconnectRequest: StreamRequest {
        StreamRequest(
            destinations: [
                RequestedDestination(id: "destination-1", url: "rtmp://localhost/live", streamKey: "test_key")
            ],
            recording: nil,
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(reconnectAttempts: 0, statsIntervalSeconds: 0)
        )
    }

    /// Asserts that a session the coordinator has released is gone in every
    /// way that matters: nothing is streaming, the id resolves to nothing —
    /// so the legs holding its stream key are gone with it — and a fresh
    /// start is accepted rather than refused as a conflict.
    private func expectFullyReleased(_ coordinator: StreamCoordinator, endedSession id: String) async throws {
        #expect(await coordinator.isStreaming == false)
        do {
            _ = try await coordinator.statusReport(sessionId: id)
            Issue.record("status for an ended session should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
        }
        let next = try await coordinator.start(generatorRequest)
        _ = try await coordinator.stop(sessionId: next)
    }

    @Test("a session that ends on its own duration releases the coordinator")
    func durationElapseReleasesSession() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(durationLimitedRequest)
        await coordinator.waitForEnd(sessionId: id)
        try await expectFullyReleased(coordinator, endedSession: id)
    }

    @Test("a lost connection with reconnect disabled releases the coordinator")
    func connectionLossReleasesSession() async throws {
        let (coordinator, service, _) = try await makeCoordinator()
        let id = try await coordinator.start(noReconnectRequest)
        // The accept-then-drop shape: the publish is accepted, then the
        // destination drops it (MediaMTX's bad-key behavior, SIMULATOR.md).
        service.reportConnectionLoss()
        await coordinator.waitForEnd(sessionId: id)
        try await expectFullyReleased(coordinator, endedSession: id)
    }

    @Test("start goes live and returns a session id")
    func startReturnsSessionID() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)
        #expect(id.hasPrefix("stream-"))
        #expect(await coordinator.isStreaming)
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a second start while one is active returns an invalidArgument error naming the active session")
    func conflictingStartIsRefused() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)
        await #expect(throws: ToolError.self) {
            _ = try await coordinator.start(generatorRequest)
        }
        do {
            _ = try await coordinator.start(generatorRequest)
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
            #expect(error.message.contains(id))
        }
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a rejected connection surfaces as a connectionFailed tool error and nothing stays active")
    func startFailureSurfacesIdentifier() async throws {
        let (coordinator, _, _) = try await makeCoordinator(startError: .connectionRejected("bad key"))
        do {
            _ = try await coordinator.start(generatorRequest)
            Issue.record("start should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .connectionFailed)
        }
        #expect(await coordinator.isStreaming == false)
    }

    @Test("status reports the live state and url for the active session")
    func statusReport() async throws {
        // Attached, so the session's own `stream.destination.started` reaches
        // the sink: the state is derived from the legs, and a leg is live from
        // the moment it connects rather than from its first stats sample.
        let (coordinator, bus, sink, attach) = try await makeAttachedCoordinator()
        let id = try await coordinator.start(generatorRequest)
        #expect(
            await eventually {
                await sink.latestEvent(named: "stream.destination.started", forDestination: "destination-1") != nil
            })

        let report = try await coordinator.statusReport(sessionId: id)
        #expect(report["sessionId"] == .string(id))
        #expect(report["state"] == .string("live"))
        #expect(report["url"] == .string("rtmp://localhost/live"))

        try await teardown(coordinator, bus, sink, attach)
    }

    @Test("status lists every destination of a fanned-out session under one session id")
    func statusListsEveryDestination() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        // Two destinations are still one session — the v1 rule is unchanged.
        let id = try await coordinator.start(twoDestinationRequest)
        let report = try await coordinator.statusReport(sessionId: id)

        #expect(report["sessionId"] == .string(id))
        // The flat top-level url stays the first destination's, so a caller
        // written against one destination reads what it always did.
        #expect(report["url"] == .string("rtmp://localhost/live"))

        let destinations = try #require(report["destinations"]?.arrayValue)
        #expect(destinations.count == 2)
        #expect(destinations[0]["destination"] == .string("destination-1"))
        #expect(destinations[0]["url"] == .string("rtmp://localhost/live"))
        #expect(destinations[1]["destination"] == .string("destination-2"))
        #expect(destinations[1]["url"] == .string("rtmp://localhost/backup"))
        // No stats have been emitted yet, so each leg reads as pending.
        #expect(destinations[0]["state"] == .string("pending"))

        // Neither stream key reaches the report.
        for leg in destinations {
            for value in (leg.objectValue ?? [:]).values {
                #expect(value.stringValue != "a")
                #expect(value.stringValue != "b")
            }
        }
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("status for an unknown session id returns an invalidArgument error")
    func statusUnknownSession() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)
        do {
            _ = try await coordinator.statusReport(sessionId: "stream-nope")
            Issue.record("status should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
        }
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("stop cleanly ends the stream and stops the service")
    func stopEndsStream() async throws {
        let (coordinator, service, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)
        let result = try await coordinator.stop(sessionId: id)
        #expect(result["stopped"] == .bool(true))
        #expect(await coordinator.isStreaming == false)
        #expect(service.stops >= 1)
    }

    @Test("two concurrent starts install exactly one session, and the other is refused")
    func concurrentStartsInstallOneSession() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let request = generatorRequest

        /// Runs one start and reports its outcome, so both can be gathered
        /// without either throwing out of the test.
        func attempt() async -> Result<String, any Error> {
            do {
                return .success(try await coordinator.start(request))
            } catch {
                return .failure(error)
            }
        }

        // The conflict check reads `active`, which stays nil across the
        // destination and input resolution that follows it — so without the
        // `startInProgress` claim both of these pass the check, both build a
        // session, and both install, the second overwriting the first.
        async let first = attempt()
        async let second = attempt()
        let outcomes = await [first, second]

        let started = outcomes.compactMap { try? $0.get() }
        #expect(started.count == 1)
        let refusals = outcomes.compactMap { outcome -> ToolError? in
            guard case .failure(let error) = outcome else { return nil }
            return error as? ToolError
        }
        #expect(refusals.count == 1)
        #expect(refusals.first?.identifier == .invalidArgument)

        // The survivor is a real, stoppable session — an overwritten first
        // session would leave a live stream no id resolves to.
        let id = try #require(started.first)
        #expect(try await coordinator.statusReport(sessionId: id)["sessionId"] == .string(id))
        _ = try await coordinator.stop(sessionId: id)
        #expect(await coordinator.isStreaming == false)
    }

    @Test("a stopped session is forgotten entirely, so it retains no stream key")
    func stopReleasesTheRequestedDestinations() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)
        // While live, the coordinator holds the requested legs — which is
        // where the stream key lives for the session's lifetime.
        #expect(try await coordinator.statusReport(sessionId: id)["sessionId"] == .string(id))
        _ = try await coordinator.stop(sessionId: id)
        // After the stop, the session id resolves to nothing. This is the
        // observable form of the transient-key policy (MCP.md, "Sessions and
        // concurrency"): `Active.destinations` is the only thing holding the
        // key, so a session the coordinator can no longer report on is a key
        // it can no longer be holding. Asserting `isStreaming == false` alone
        // would only pin the flag, which could go false with the legs still
        // retained.
        do {
            _ = try await coordinator.statusReport(sessionId: id)
            Issue.record("status for a stopped session should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
        }
        #expect(await coordinator.isStreaming == false)
    }

    @Test("a start that never goes live retains nothing")
    func refusedStartRetainsNothing() async throws {
        let (coordinator, _, _) = try await makeCoordinator(startError: .connectionRejected("bad key"))
        await #expect(throws: ToolError.self) {
            _ = try await coordinator.start(generatorRequest)
        }
        // The refused start never reached `active`, so the key it carried
        // went out of scope with the request — the second of the teardown
        // paths that is not an explicit `stream_stop`.
        #expect(await coordinator.isStreaming == false)
        // And the coordinator is usable again rather than wedged: a key that
        // stayed retained would also refuse this as "already streaming".
        let id = try await coordinator.start(generatorRequest)
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("stop for an unknown session id returns an invalidArgument error")
    func stopUnknownSession() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)
        do {
            _ = try await coordinator.stop(sessionId: "stream-nope")
            Issue.record("stop should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
        }
        _ = try await coordinator.stop(sessionId: id)
    }

    // MARK: - Recording (the `record` field — MCP.md, "Tool surface")

    @Test("a session with a recording opens the file and reports it in status while it is open")
    func recordingReportsInStatus() async throws {
        let (coordinator, recording, _) = try await makeRecordingCoordinator()
        let id = try await coordinator.start(recordAlongsideRequest)
        #expect(recording.openedFile?.url.path == "/Movies/show.mp4")
        #expect(recording.openedFile?.container == .mp4)

        let report = try await coordinator.statusReport(sessionId: id)
        let object = try #require(report["recording"]?.objectValue)
        #expect(object["path"] == .string("/Movies/show.mp4"))
        #expect(object["container"] == .string("mp4"))

        // Stop finalizes the file with the session.
        _ = try await coordinator.stop(sessionId: id)
        #expect(recording.stops >= 1)
    }

    @Test("a record-only session starts, reports no url, and stops cleanly")
    func recordOnlySessionRuns() async throws {
        let (coordinator, recording, _) = try await makeRecordingCoordinator()
        let id = try await coordinator.start(recordOnlyRequest)
        // The one-session rule counts it: the idle-exit guard must not fire.
        #expect(await coordinator.isStreaming == true)

        let report = try await coordinator.statusReport(sessionId: id)
        // Live with no legs to derive from: a record-only session is doing
        // exactly what it was asked to.
        #expect(report["state"] == .string("live"))
        // No destination, so no url and an empty destinations list — never
        // a placeholder value standing in for a leg that does not exist.
        #expect(report["url"] == nil)
        #expect(report["destinations"] == .array([]))
        #expect(report["recording"]?["path"] == .string("/Movies/show.mp4"))

        _ = try await coordinator.stop(sessionId: id)
        #expect(recording.stops >= 1)
        try await expectFullyReleased(coordinator, endedSession: id)
    }

    @Test("a record-only session conflicts with a second start like any other")
    func recordOnlySessionConflicts() async throws {
        let (coordinator, _, _) = try await makeRecordingCoordinator()
        let id = try await coordinator.start(recordOnlyRequest)
        do {
            _ = try await coordinator.start(generatorRequest)
            Issue.record("a second start should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
            #expect(error.message.contains(id))
        }
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a recording no registered output serves returns a recordingFailed error")
    func recordingWithoutProviderReturnsAnError() async throws {
        // The plain coordinator has no recording provider registered.
        let (coordinator, _, _) = try await makeCoordinator()
        do {
            _ = try await coordinator.start(recordAlongsideRequest)
            Issue.record("start should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .recordingFailed)
        }
        // Nothing half-started: the coordinator accepts a fresh start.
        #expect(await coordinator.isStreaming == false)
        let id = try await coordinator.start(generatorRequest)
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a recording that cannot open returns a recordingFailed error and retains nothing")
    func recordingSetupErrorReleasesTheSession() async throws {
        let (coordinator, _, _) = try await makeRecordingCoordinator(
            recordingStartError: .unwritableDestination("the volume cannot hold five minutes"))
        do {
            _ = try await coordinator.start(recordAlongsideRequest)
            Issue.record("start should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .recordingFailed)
        }
        #expect(await coordinator.isStreaming == false)
        // Usable again: the mock refuses only its first start.
        let id = try await coordinator.start(recordAlongsideRequest)
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a write error mid-session ends a record-only session and releases the coordinator")
    func writeErrorEndsRecordOnlySession() async throws {
        let (coordinator, recording, _) = try await makeRecordingCoordinator()
        let id = try await coordinator.start(recordOnlyRequest)
        recording.reportWriteFailure(reason: "disk full")
        // The failed file sink was the session's only one, so the session
        // ends (`stream.stopped`, reason `recordingFailed`) and releases.
        await coordinator.waitForEnd(sessionId: id)
        try await expectFullyReleased(coordinator, endedSession: id)
    }

    @Test("a write error mid-session leaves a streaming session live and drops recording from status")
    func writeErrorLeavesStreamingSessionLive() async throws {
        let (coordinator, recording, _) = try await makeRecordingCoordinator()
        let id = try await coordinator.start(recordAlongsideRequest)
        recording.reportWriteFailure(reason: "disk full")

        // The recording object leaves the report once the write failure
        // lands — the rejected-leg absence contract — while the session
        // itself stays live on its destination.
        var recordingGone = false
        for _ in 0..<200 {
            let report = try await coordinator.statusReport(sessionId: id)
            if report["recording"] == nil {
                recordingGone = true
                // The session itself is untouched — still the active one, and
                // still streaming (asserted below).
                #expect(report["sessionId"] == .string(id))
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recordingGone)
        #expect(await coordinator.isStreaming == true)
        _ = try await coordinator.stop(sessionId: id)
    }

    // MARK: - Session addressing (an omitted session id — MCP.md, "Tool surface")

    @Test("status and stop without a session id address the active stream")
    func omittedSessionIdAddressesActiveStream() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)

        let report = try await coordinator.statusReport(sessionId: nil)
        #expect(report["sessionId"] == .string(id))
        // This sink is not attached to the bus, so no leg has reported and the
        // derived state is pending — the addressing is what is under test.
        #expect(report["state"] == .string("pending"))

        // Stop resolves the same way and confirms which session it stopped.
        let result = try await coordinator.stop(sessionId: nil)
        #expect(result["sessionId"] == .string(id))
        #expect(result["stopped"] == .bool(true))
        #expect(await coordinator.isStreaming == false)
    }

    @Test("status without a session id on an idle engine reports the idle state")
    func idleStatusReportsIdle() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let report = try await coordinator.statusReport(sessionId: nil)
        // A truthful answer, not an error — and no session fields to
        // mistake for one.
        #expect(report == .object(["state": .string("idle")]))
    }

    @Test("stop without a session id on an idle engine returns a noActiveStream error")
    func idleStopReturnsNoActiveStream() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        do {
            _ = try await coordinator.stop(sessionId: nil)
            Issue.record("stop should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .noActiveStream)
        }
    }

    // MARK: - Leg states (derived from the sink's retained events)

    /// Builds a coordinator whose status sink is attached to the event bus,
    /// so tests can put per-leg status events on the bus and read the states
    /// `stream_status` derives from them. Returns the sink and its attach
    /// task for orderly teardown.
    private func makeAttachedCoordinator() async throws
        -> (StreamCoordinator, EventBus, StatusSink, Task<Void, Never>)
    {
        let eventBus = EventBus()
        let inputs = InputRegistry()
        try await inputs.register(StubInput(id: "bars", name: "SMPTE Bars", kind: .generator))
        try await inputs.register(StubInput(id: "tone", name: "440 Hz Tone", kind: .generator))
        let outputs = OutputRegistry()
        try await outputs.register(MockProvider(service: MockStreamingService()))
        let sink = StatusSink()
        let attach = eventBus.attach(sink)
        let coordinator = StreamCoordinator(
            inputs: inputs,
            outputs: outputs,
            status: sink,
            eventBus: eventBus,
            clock: FinishingClock(),
            defaults: StreamDefaults(cameraID: { nil }, microphoneID: { nil })
        )
        return (coordinator, eventBus, sink, attach)
    }

    /// Ends an attached-coordinator test in order: stream, bus, sink.
    private func teardown(
        _ coordinator: StreamCoordinator, _ bus: EventBus, _ sink: StatusSink, _ attach: Task<Void, Never>
    ) async throws {
        if await coordinator.isStreaming {
            _ = try await coordinator.stop(sessionId: nil)
        }
        bus.shutdown()
        await attach.value
        await sink.shutdown()
    }

    /// The state of the first (and only) leg in a status report.
    private func firstLegState(_ report: JSONValue) throws -> JSONValue? {
        try #require(report["destinations"]?.arrayValue).first?["state"]
    }

    @Test("a leg reports reconnecting after a drop and live again after recovery")
    func legStateFollowsReconnectCycle() async throws {
        let (coordinator, bus, sink, attach) = try await makeAttachedCoordinator()
        _ = try await coordinator.start(generatorRequest)
        let leg = "destination-1"

        bus.event("stream.stats", domain: .output, params: ["destination": .string(leg), "fps": .int(30)])
        #expect(await eventually { await sink.latestEvent(named: "stream.stats", forDestination: leg) != nil })
        #expect(try firstLegState(try await coordinator.statusReport(sessionId: nil)) == .string("live"))

        bus.event("stream.reconnecting", domain: .output, params: ["destination": .string(leg), "attempt": .int(1)])
        #expect(await eventually { await sink.latestEvent(named: "stream.reconnecting", forDestination: leg) != nil })
        let reconnecting = try await coordinator.statusReport(sessionId: nil)
        #expect(try firstLegState(reconnecting) == .string("reconnecting"))
        // The last stats stay on the leg — the last truth; `state` says
        // whether they are current.
        #expect(try #require(reconnecting["destinations"]?.arrayValue).first?["fps"] == .int(30))

        bus.event("stream.reconnected", domain: .output, params: ["destination": .string(leg), "outage": .double(1.5)])
        #expect(await eventually { await sink.latestEvent(named: "stream.reconnected", forDestination: leg) != nil })
        #expect(try firstLegState(try await coordinator.statusReport(sessionId: nil)) == .string("live"))

        try await teardown(coordinator, bus, sink, attach)
    }

    @Test("a leg that exhausted its reconnect budget reports lost")
    func legStateReportsLost() async throws {
        let (coordinator, bus, sink, attach) = try await makeAttachedCoordinator()
        _ = try await coordinator.start(generatorRequest)
        let leg = "destination-1"

        bus.error("stream.destination.lost", domain: .output, params: ["destination": .string(leg)])
        #expect(
            await eventually { await sink.latestEvent(named: "stream.destination.lost", forDestination: leg) != nil })
        #expect(try firstLegState(try await coordinator.statusReport(sessionId: nil)) == .string("lost"))

        try await teardown(coordinator, bus, sink, attach)
    }

    @Test("a leg the destination refused at start reports rejected")
    func legStateReportsRejected() async throws {
        let (coordinator, bus, sink, attach) = try await makeAttachedCoordinator()
        _ = try await coordinator.start(generatorRequest)
        let leg = "destination-1"

        bus.error("stream.destination.rejected", domain: .output, params: ["destination": .string(leg)])
        #expect(
            await eventually {
                await sink.latestEvent(named: "stream.destination.rejected", forDestination: leg) != nil
            }
        )
        #expect(try firstLegState(try await coordinator.statusReport(sessionId: nil)) == .string("rejected"))

        try await teardown(coordinator, bus, sink, attach)
    }

    @Test("a previous session's retained events never reach a fresh session's report")
    func previousSessionEventsStayOut() async throws {
        let (coordinator, bus, sink, attach) = try await makeAttachedCoordinator()
        let leg = "destination-1"

        // A previous session used the same leg id — leg ids are positional
        // and repeat every session — and left its verdicts in the sink.
        bus.event("stream.stats", domain: .output, params: ["destination": .string(leg), "bitrate": .int(4_500_000)])
        bus.error("stream.destination.lost", domain: .output, params: ["destination": .string(leg)])
        #expect(
            await eventually { await sink.latestEvent(named: "stream.destination.lost", forDestination: leg) != nil })

        _ = try await coordinator.start(generatorRequest)
        // Wait for the fresh session's own connection event before reading, so
        // the assertion turns on the floor rather than on which event happened
        // to arrive first. The previous "session" here emitted no
        // `stream.destination.started`, so seeing one means the new leg's
        // evidence is in the sink alongside the old leg's `lost` verdict.
        #expect(
            await eventually {
                await sink.latestEvent(named: "stream.destination.started", forDestination: leg) != nil
            })

        let report = try await coordinator.statusReport(sessionId: nil)
        // The fresh leg is live — not lost, and not wearing the old session's
        // counters.
        #expect(try firstLegState(report) == .string("live"))
        #expect(try #require(report["destinations"]?.arrayValue).first?["bitrate"] == nil)
        #expect(report["bitrate"] == nil)

        try await teardown(coordinator, bus, sink, attach)
    }

    // MARK: - Session state (derived from the legs — MCP.md, "Tool surface")

    @Test("the session state answers whether the stream is delivering, leg by leg")
    func sessionStateDerivation() {
        // No legs at all: a record-only session is doing exactly what it was
        // asked to.
        #expect(StreamCoordinator.sessionState(ofLegs: []) == "live")
        #expect(StreamCoordinator.sessionState(ofLegs: ["live"]) == "live")
        #expect(StreamCoordinator.sessionState(ofLegs: ["live", "live"]) == "live")
        // A leg that has not reported yet is not evidence against a session
        // that is otherwise delivering — otherwise a two-leg session would
        // read degraded on the way up, before its second leg was heard from.
        #expect(StreamCoordinator.sessionState(ofLegs: ["live", "pending"]) == "live")
        #expect(StreamCoordinator.sessionState(ofLegs: ["pending"]) == "pending")
        #expect(StreamCoordinator.sessionState(ofLegs: ["pending", "pending"]) == "pending")
        // Something is wrong and recovery is still possible — including when
        // nothing is delivering but a reconnect budget is still being spent.
        #expect(StreamCoordinator.sessionState(ofLegs: ["live", "lost"]) == "degraded")
        #expect(StreamCoordinator.sessionState(ofLegs: ["live", "rejected"]) == "degraded")
        #expect(StreamCoordinator.sessionState(ofLegs: ["reconnecting"]) == "degraded")
        #expect(StreamCoordinator.sessionState(ofLegs: ["live", "reconnecting"]) == "degraded")
        // A pending leg may still come good, so the session has not ended.
        #expect(StreamCoordinator.sessionState(ofLegs: ["pending", "lost"]) == "degraded")
        // Every leg ended; nothing recovers without a new session.
        #expect(StreamCoordinator.sessionState(ofLegs: ["lost"]) == "lost")
        #expect(StreamCoordinator.sessionState(ofLegs: ["lost", "rejected"]) == "lost")
        #expect(StreamCoordinator.sessionState(ofLegs: ["rejected", "rejected"]) == "lost")
    }

    @Test("a fanned-out session reads degraded while one leg is down and the other delivers")
    func sessionStateReportsDegraded() async throws {
        let (coordinator, bus, sink, attach) = try await makeAttachedCoordinator()
        _ = try await coordinator.start(twoDestinationRequest)
        // The session emits its legs' connection events in order, so the
        // second one's arrival means both are in the sink.
        #expect(
            await eventually {
                await sink.latestEvent(named: "stream.destination.started", forDestination: "destination-2") != nil
            })
        #expect(try await coordinator.statusReport(sessionId: nil)["state"] == .string("live"))

        bus.error("stream.destination.lost", domain: .output, params: ["destination": .string("destination-2")])
        #expect(
            await eventually {
                await sink.latestEvent(named: "stream.destination.lost", forDestination: "destination-2") != nil
            })

        // The headline no longer contradicts the legs: half this stream is on
        // the floor, and `state` says so without the caller reading them.
        let report = try await coordinator.statusReport(sessionId: nil)
        #expect(report["state"] == .string("degraded"))
        let legs = try #require(report["destinations"]?.arrayValue)
        #expect(legs.first?["state"] == .string("live"))
        #expect(legs.last?["state"] == .string("lost"))

        try await teardown(coordinator, bus, sink, attach)
    }

    @Test("a fanned-out session reads lost once every leg has ended")
    func sessionStateReportsLost() async throws {
        let (coordinator, bus, sink, attach) = try await makeAttachedCoordinator()
        _ = try await coordinator.start(twoDestinationRequest)
        #expect(
            await eventually {
                await sink.latestEvent(named: "stream.destination.started", forDestination: "destination-2") != nil
            })

        // The two terminal verdicts differ; together they still end the
        // session's delivery entirely.
        bus.error("stream.destination.rejected", domain: .output, params: ["destination": .string("destination-1")])
        bus.error("stream.destination.lost", domain: .output, params: ["destination": .string("destination-2")])
        #expect(
            await eventually {
                let rejected = await sink.latestEvent(
                    named: "stream.destination.rejected", forDestination: "destination-1")
                let lost = await sink.latestEvent(named: "stream.destination.lost", forDestination: "destination-2")
                return rejected != nil && lost != nil
            })

        #expect(try await coordinator.statusReport(sessionId: nil)["state"] == .string("lost"))

        try await teardown(coordinator, bus, sink, attach)
    }
}
