//
//  StreamCoordinatorDestinationTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-08-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraMCP

/// The `destination` selector on `stream_start`, resolved by the coordinator
/// against the operator's store (DESTINATIONS.md, "The tool surface").
@Suite("stream_start destination selector")
struct StreamCoordinatorDestinationTests {
    /// Builds a coordinator over a mock output and an optional destination
    /// store, returning the mock service so a test can read the URL and key
    /// the leg actually published with.
    ///
    /// - Parameter destinationStore: The store a selector resolves against,
    ///   or nil to leave the coordinator without one.
    /// - Returns: The coordinator and the mock streaming service.
    private func makeCoordinator(
        destinationStore: DestinationStore? = nil
    ) async throws -> (StreamCoordinator, MockStreamingService) {
        let inputs = InputRegistry()
        try await inputs.register(StubInput(id: "bars", name: "SMPTE Bars", kind: .generator))
        try await inputs.register(StubInput(id: "tone", name: "440 Hz Tone", kind: .generator))
        let outputs = OutputRegistry()
        let service = MockStreamingService()
        try await outputs.register(MockProvider(service: service))
        let coordinator = StreamCoordinator(
            inputs: inputs,
            outputs: outputs,
            status: StatusSink(),
            eventBus: EventBus(),
            clock: FinishingClock(),
            defaults: StreamDefaults(cameraID: { nil }, microphoneID: { nil }),
            destinationStore: destinationStore
        )
        return (coordinator, service)
    }

    /// A generator-fed request to the given destinations.
    ///
    /// - Parameter destinations: The destinations as the tool parsed them.
    /// - Returns: The request.
    private func request(_ destinations: [RequestedDestinationSpec]) -> StreamRequest {
        StreamRequest(
            destinations: destinations,
            recording: nil,
            video: .generator(InputID(rawValue: "bars")),
            audio: .generator(InputID(rawValue: "tone")),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
    }

    /// The error a start throws, or nil when it goes live.
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator to start.
    ///   - destinations: The destinations to start to.
    /// - Returns: The thrown ``ToolError``, or nil.
    private func startError(
        _ coordinator: StreamCoordinator,
        _ destinations: [RequestedDestinationSpec]
    ) async -> ToolError? {
        do {
            _ = try await coordinator.start(request(destinations))
            return nil
        } catch let error as ToolError {
            return error
        } catch {
            return ToolError(identifier: .pipelineError, message: "\(error)")
        }
    }

    @Test("a saved destination streams to its stored url with its stored key")
    func resolvesSavedDestination() async throws {
        let fixture = try await DestinationFixture(
            destinations: [savedDestination()], keys: ["dest-twitch": "live_abc123"])
        let (coordinator, service) = try await makeCoordinator(destinationStore: fixture.store)

        let id = try await coordinator.start(request([.saved(id: "destination-1", selector: "Twitch")]))

        #expect(service.startedDestination?.url.absoluteString == "rtmp://localhost/live")
        #expect(service.startedDestination?.streamKey == "live_abc123")
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a saved destination resolves by id as readily as by name")
    func resolvesById() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let (coordinator, service) = try await makeCoordinator(destinationStore: fixture.store)

        let id = try await coordinator.start(request([.saved(id: "destination-1", selector: "dest-twitch")]))

        #expect(service.startedDestination?.url.absoluteString == "rtmp://localhost/live")
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a saved destination with no stored key streams keyless")
    func keylessSavedDestination() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let (coordinator, service) = try await makeCoordinator(destinationStore: fixture.store)

        let id = try await coordinator.start(request([.saved(id: "destination-1", selector: "Twitch")]))

        #expect(service.startedDestination?.streamKey == nil)
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("status reports the resolved url for a saved leg, so an agent can confirm which one went live")
    func statusReportsResolvedURL() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let (coordinator, _) = try await makeCoordinator(destinationStore: fixture.store)

        let id = try await coordinator.start(request([.saved(id: "destination-1", selector: "Twitch")]))

        let report = try await coordinator.statusReport(sessionId: id)
        #expect(report["url"] == .string("rtmp://localhost/live"))
        let legs = try #require(report["destinations"]?.arrayValue)
        #expect(legs.first?["url"] == .string("rtmp://localhost/live"))
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a saved leg and a raw leg resolve independently in one session")
    func mixedLegs() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let (coordinator, _) = try await makeCoordinator(destinationStore: fixture.store)

        let id = try await coordinator.start(
            request([
                .saved(id: "destination-1", selector: "Twitch"),
                .raw(id: "destination-2", url: "rtmp://localhost/backup", key: "backup_key"),
            ]))

        let legs = try #require(try await coordinator.statusReport(sessionId: id)["destinations"]?.arrayValue)
        #expect(legs.count == 2)
        #expect(legs[0]["url"] == .string("rtmp://localhost/live"))
        #expect(legs[1]["url"] == .string("rtmp://localhost/backup"))
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a selector matching nothing returns destinationNotFound and nothing stays active")
    func unknownSelector() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let (coordinator, _) = try await makeCoordinator(destinationStore: fixture.store)

        let error = await startError(coordinator, [.saved(id: "destination-1", selector: "vimeo")])

        #expect(error?.identifier == .destinationNotFound)
        #expect(await coordinator.isStreaming == false)
    }

    @Test("a name matching several destinations returns destinationAmbiguous listing them")
    func ambiguousSelector() async throws {
        let fixture = try await DestinationFixture(destinations: [
            savedDestination(id: "dest-1", name: "Twitch main"),
            savedDestination(id: "dest-2", name: "Twitch backup", url: "rtmp://localhost/backup"),
        ])
        let (coordinator, _) = try await makeCoordinator(destinationStore: fixture.store)

        let error = await startError(coordinator, [.saved(id: "destination-1", selector: "twitch")])

        #expect(error?.identifier == .destinationAmbiguous)
        #expect(error?.message.contains("Twitch main") == true)
        #expect(error?.message.contains("Twitch backup") == true)
    }

    @Test("a selector with no destination store configured returns destinationNotFound")
    func noStoreConfigured() async throws {
        let (coordinator, _) = try await makeCoordinator()

        let error = await startError(coordinator, [.saved(id: "destination-1", selector: "Twitch")])

        #expect(error?.identifier == .destinationNotFound)
        #expect(error?.message.contains("no destination store") == true)
    }

    @Test("a stored key this process cannot read returns an error naming the fix")
    func unreadableKey() async throws {
        let fixture = try await DestinationFixture(
            destinations: [savedDestination()],
            keys: ["dest-twitch": "live_abc123"],
            readFailure: .keychain(-34018)
        )
        let (coordinator, _) = try await makeCoordinator(destinationStore: fixture.store)

        let error = await startError(coordinator, [.saved(id: "destination-1", selector: "Twitch")])

        #expect(error?.identifier == .pipelineError)
        #expect(error?.message.contains("separate binaries in separate groups") == true)
        #expect(await coordinator.isStreaming == false)
    }

    @Test("a raw leg still streams when the coordinator has no destination store")
    func rawLegUnaffected() async throws {
        let (coordinator, service) = try await makeCoordinator()

        let id = try await coordinator.start(
            request([.raw(id: "destination-1", url: "rtmp://localhost/live", key: "inline_key")]))

        #expect(service.startedDestination?.streamKey == "inline_key")
        _ = try await coordinator.stop(sessionId: id)
    }

    @Test("a key resolved from the store is released with the session, like an inline one")
    func resolvedKeyIsTransient() async throws {
        let fixture = try await DestinationFixture(
            destinations: [savedDestination()], keys: ["dest-twitch": "live_abc123"])
        let (coordinator, _) = try await makeCoordinator(destinationStore: fixture.store)
        let id = try await coordinator.start(request([.saved(id: "destination-1", selector: "Twitch")]))

        _ = try await coordinator.stop(sessionId: id)

        // The legs are the only thing holding the key, so an id that no
        // longer resolves is the key having been released.
        #expect(await coordinator.isStreaming == false)
        await #expect(throws: ToolError.self) {
            _ = try await coordinator.statusReport(sessionId: id)
        }
    }
}
