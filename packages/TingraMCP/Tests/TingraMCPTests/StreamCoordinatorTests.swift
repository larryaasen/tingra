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
            url: "rtmp://localhost/live",
            streamKey: "test_key",
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
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
