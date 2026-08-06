//
//  StreamCoordinatorTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

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

    /// A generator-only request to the mock destination.
    private var generatorRequest: StreamRequest {
        StreamRequest(
            destinations: [
                RequestedDestination(id: "destination-1", url: "rtmp://localhost/live", streamKey: "test_key")
            ],
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
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)
        let report = try await coordinator.statusReport(sessionId: id)
        #expect(report["sessionId"] == .string(id))
        #expect(report["state"] == .string("live"))
        #expect(report["url"] == .string("rtmp://localhost/live"))
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("status lists every destination of a fanned-out session under one session id")
    func statusListsEveryDestination() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let request = StreamRequest(
            destinations: [
                RequestedDestination(id: "destination-1", url: "rtmp://localhost/live", streamKey: "a"),
                RequestedDestination(id: "destination-2", url: "rtmp://localhost/backup", streamKey: "b"),
            ],
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
        // Two destinations are still one session — the v1 rule is unchanged.
        let id = try await coordinator.start(request)
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
        #expect(try await coordinator.statusReport(sessionId: id)["state"] == .string("live"))
        _ = try await coordinator.stop(sessionId: id)
        #expect(await coordinator.isStreaming == false)
    }

    @Test("a stopped session is forgotten entirely, so it retains no stream key")
    func stopReleasesTheRequestedDestinations() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let id = try await coordinator.start(generatorRequest)
        // While live, the coordinator holds the requested legs — which is
        // where the stream key lives for the session's lifetime.
        #expect(try await coordinator.statusReport(sessionId: id)["state"] == .string("live"))
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
}
