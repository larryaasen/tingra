//
//  StreamSessionFanOutTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraHost

/// The multiple-destinations behavior: one program fanned out to N legs, with
/// per-leg reconnect state, per-leg status events, and a run that survives a
/// partial loss (ARCHITECTURE.md, "Multiple destinations").
@Suite("StreamSession fan-out")
struct StreamSessionFanOutTests {
    /// Builds a leg streaming to `rtmp://localhost:1935/<id>`.
    ///
    /// - Parameters:
    ///   - id: The leg's stable identity in status events.
    ///   - service: The mock service standing in for that destination.
    /// - Returns: The configured leg.
    private static func makeLeg(
        id: String,
        service: MockStreamingService
    ) throws -> StreamSession.DestinationLeg {
        StreamSession.DestinationLeg(
            id: id,
            destination: Destination(
                url: try #require(URL(string: "rtmp://localhost:1935/\(id)")),
                streamKey: "tingra_test_key"
            ),
            service: service
        )
    }

    /// Builds a session fanning one stub camera and microphone out to `legs`.
    private static func makeSession(
        legs: [StreamSession.DestinationLeg],
        clock: any EngineClock,
        eventBus: EventBus,
        policy: StreamSession.Policy,
        videoFrames: [CapturedFrame] = [],
        audioBuffers: [CapturedAudio] = []
    ) -> StreamSession {
        StreamSession(
            videoInput: StubInput(
                id: "camera-1",
                name: "Stub Camera",
                kind: .camera,
                frames: videoFrames
            ),
            audioInput: StubInput(
                id: "mic-1",
                name: "Stub Microphone",
                kind: .microphone,
                audio: audioBuffers
            ),
            destinations: legs,
            configuration: StreamConfiguration(),
            policy: policy,
            clock: clock,
            eventBus: eventBus
        )
    }

    /// Drives `clock` forward one second at a time until cancelled, so the
    /// session's reconnect delays and stats ticks resolve without wall time.
    private static func advancing(_ clock: ManualClock) -> Task<Void, Never> {
        Task {
            var seconds = 1.0
            while !Task.isCancelled {
                clock.advance(to: CMTime(seconds: seconds, preferredTimescale: 600))
                seconds += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @Test("Every leg receives the same program on the one session timeline")
    func everyLegReceivesTheProgram() async throws {
        let clock = ManualClock()
        clock.advance(to: CMTime(value: 10, timescale: 1))
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let primary = MockStreamingService()
        let secondary = MockStreamingService()
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: primary),
                try Self.makeLeg(id: "youtube", service: secondary),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 0),
            audioBuffers: [try #require(makeTestAudio(pts: CMTime(value: 105, timescale: 10)))]
        )
        let runTask = Task { try await session.run() }

        let started = await eventually { !events.named("stream.started").isEmpty }
        #expect(started)
        #expect(primary.starts.count == 1)
        #expect(secondary.starts.count == 1)

        // One program, one T0: both legs get the identical rebased PTS
        // (10.5s − 10s = 0.5s), which is the whole reason this is one session.
        let delivered = await eventually { !primary.audioTimes.isEmpty && !secondary.audioTimes.isEmpty }
        #expect(delivered)
        #expect(primary.audioTimes.first == CMTime(value: 5, timescale: 10))
        #expect(secondary.audioTimes.first == CMTime(value: 5, timescale: 10))

        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)
        #expect(primary.stops == 1)
        #expect(secondary.stops == 1)

        // The session summarizes the fan-out and names each leg once.
        let startedParams = try #require(events.named("stream.started").first?.params)
        #expect(startedParams["destinations"] == .int(2))
        #expect(startedParams["destinationsRejected"] == .int(0))
        #expect(startedParams["url"] == .string("rtmp://localhost:1935/twitch"))
        #expect(events.named("stream.destination.started", forDestination: "twitch").count == 1)
        #expect(events.named("stream.destination.started", forDestination: "youtube").count == 1)

        // The stream key reaches neither the bus nor a destination URL.
        for event in events.all {
            for value in (event.params ?? [:]).values {
                if case .string(let string) = value {
                    #expect(!string.contains("tingra_test_key"))
                }
            }
        }
    }

    @Test("Stats are reported per leg, each carrying its own destination identity")
    func statsAreReportedPerLeg() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let primary = MockStreamingService(
            statistics: StreamingStatistics(bytesSent: 9000, bytesPerSecond: 500, framesPerSecond: 30)
        )
        let secondary = MockStreamingService(
            statistics: StreamingStatistics(bytesSent: 400, bytesPerSecond: 100, framesPerSecond: 24)
        )
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: primary),
                try Self.makeLeg(id: "youtube", service: secondary),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 5)
        )
        let runTask = Task { try await session.run() }
        let advancer = Self.advancing(clock)
        defer { advancer.cancel() }

        let statsArrived = await eventually {
            !events.named("stream.stats", forDestination: "twitch").isEmpty
                && !events.named("stream.stats", forDestination: "youtube").isEmpty
        }
        #expect(statsArrived)

        // Each leg reports its own counters — never an average that describes
        // neither destination.
        let primaryStats = try #require(events.named("stream.stats", forDestination: "twitch").first)
        #expect(primaryStats.params?["bytesSent"] == .int(9000))
        #expect(primaryStats.params?["bitrate"] == .int(4000))
        #expect(primaryStats.params?["fps"] == .int(30))
        #expect(primaryStats.params?["destinationUrl"] == .string("rtmp://localhost:1935/twitch"))

        let secondaryStats = try #require(events.named("stream.stats", forDestination: "youtube").first)
        #expect(secondaryStats.params?["bytesSent"] == .int(400))
        #expect(secondaryStats.params?["bitrate"] == .int(800))
        #expect(secondaryStats.params?["fps"] == .int(24))

        await session.stop()
        _ = try await runTask.value
    }

    @Test("A destination rejected at start is reported and the run goes live on the rest")
    func partialStartRejectionGoesLive() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let accepted = MockStreamingService()
        let rejected = MockStreamingService()
        rejected.failNextStarts(with: [.connectionRejected("bad stream key")])
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: rejected),
                try Self.makeLeg(id: "youtube", service: accepted),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(reconnectAttempts: 2, statsIntervalSeconds: 5)
        )
        let runTask = Task { try await session.run() }
        let advancer = Self.advancing(clock)
        defer { advancer.cancel() }

        let started = await eventually { !events.named("stream.started").isEmpty }
        #expect(started)

        // Best effort: the run is live on the leg that connected, and `url`
        // names that leg rather than the one that was refused.
        let startedParams = try #require(events.named("stream.started").first?.params)
        #expect(startedParams["destinations"] == .int(1))
        #expect(startedParams["destinationsRejected"] == .int(1))
        #expect(startedParams["url"] == .string("rtmp://localhost:1935/youtube"))

        // The refusal is loud — an error event with a stable identifier —
        // without changing the run's fate.
        let refusal = try #require(events.named("stream.destination.rejected", forDestination: "twitch").first)
        #expect(refusal.params?["identifier"] == .string("connectionFailed"))
        #expect(refusal.group == .error)
        #expect(events.named("stream.destination.started", forDestination: "twitch").isEmpty)

        // A leg refused at start does not enter the reconnect budget: the
        // budget governs mid-stream losses, not a destination that was wrong
        // from the first handshake.
        let statsArrived = await eventually { !events.named("stream.stats", forDestination: "youtube").isEmpty }
        #expect(statsArrived)
        #expect(events.named("stream.reconnecting").isEmpty)
        #expect(events.named("stream.stats", forDestination: "twitch").isEmpty)

        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)
    }

    @Test("A run whose every destination is rejected throws from run")
    func everyDestinationRejectedThrows() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let first = MockStreamingService()
        first.failNextStarts(with: [.connectionRejected("first refused")])
        let second = MockStreamingService()
        second.failNextStarts(with: [.connectionRejected("second refused")])
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: first),
                try Self.makeLeg(id: "youtube", service: second),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )

        // The first leg's error surfaces, so the caller maps a total failure
        // to connectionFailed exactly as a single destination always did.
        await #expect(throws: StreamingServiceError.connectionRejected("first refused")) {
            _ = try await session.run()
        }
        // Both refusals were still reported individually, and nothing went live.
        let reported = await eventually { events.named("stream.destination.rejected").count == 2 }
        #expect(reported)
        #expect(events.named("stream.started").isEmpty)
    }

    @Test("A session configured with no destinations returns an error")
    func noDestinationsReturnsAnError() async throws {
        let session = Self.makeSession(
            legs: [],
            clock: ManualClock(),
            eventBus: EventBus(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
        await #expect(throws: StreamingServiceError.self) {
            _ = try await session.run()
        }
    }

    @Test("One destination exhausting its budget is reported while the others keep streaming")
    func partialLegLossKeepsTheRunAlive() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let failing = MockStreamingService()
        let healthy = MockStreamingService()
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: failing),
                try Self.makeLeg(id: "youtube", service: healthy),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(
                reconnectAttempts: 2,
                reconnectDelaySeconds: 1,
                statsIntervalSeconds: 5
            )
        )
        let runTask = Task { try await session.run() }
        let advancer = Self.advancing(clock)
        defer { advancer.cancel() }

        _ = await eventually { failing.starts.count == 1 && healthy.starts.count == 1 }
        failing.failNextStarts(with: [
            .connectionRejected("first attempt refused"),
            .connectionRejected("second attempt refused"),
        ])
        failing.reportConnectionLost(reason: "NetConnection.Connect.Closed")

        // That leg drains its own budget and dies; the session does not.
        let lost = await eventually { !events.named("stream.destination.lost", forDestination: "twitch").isEmpty }
        #expect(lost)
        let lostEvent = try #require(events.named("stream.destination.lost", forDestination: "twitch").first)
        #expect(lostEvent.params?["identifier"] == .string("connectionLost"))
        #expect(lostEvent.group == .error)
        #expect(events.named("stream.reconnecting", forDestination: "twitch").count == 2)
        #expect(events.named("stream.reconnecting", forDestination: "youtube").isEmpty)

        // The surviving leg keeps reporting; the dead one stops reporting.
        let statsBefore = events.named("stream.stats", forDestination: "twitch").count
        let healthyKeepsGoing = await eventually {
            events.named("stream.stats", forDestination: "youtube").count > 1
        }
        #expect(healthyKeepsGoing)
        #expect(events.named("stream.stats", forDestination: "twitch").count == statsBefore)

        // A partial loss exits cleanly — exit 75 belongs to the last leg only.
        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)
    }

    @Test("Losing the last live destination ends the session with connectionLost")
    func lastLegLossEndsTheSession() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let first = MockStreamingService()
        let second = MockStreamingService()
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: first),
                try Self.makeLeg(id: "youtube", service: second),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(reconnectAttempts: 0, statsIntervalSeconds: 0)
        )
        let runTask = Task { try await session.run() }
        let advancer = Self.advancing(clock)
        defer { advancer.cancel() }

        _ = await eventually { first.starts.count == 1 && second.starts.count == 1 }

        // With reconnect disabled each loss kills its leg outright. The first
        // one must not end the run; the second one must.
        first.reportConnectionLost(reason: "NetConnection.Connect.Closed")
        let firstLost = await eventually { !events.named("stream.destination.lost", forDestination: "twitch").isEmpty }
        #expect(firstLost)
        #expect(!runTask.isCancelled)
        #expect(events.named("stream.stopped").isEmpty)

        second.reportConnectionLost(reason: "NetConnection.Connect.Closed")
        let outcome = try await runTask.value
        #expect(outcome == .connectionLost)

        let stoppedArrived = await eventually { !events.named("stream.stopped").isEmpty }
        #expect(stoppedArrived)
        #expect(events.named("stream.stopped").first?.params?["reason"] == .string("connectionLost"))
    }

    @Test("One destination's outage does not drain another destination's attempt budget")
    func legBudgetsAreIndependent() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let flapping = MockStreamingService()
        let steady = MockStreamingService()
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: flapping),
                try Self.makeLeg(id: "youtube", service: steady),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(
                reconnectAttempts: 2,
                reconnectDelaySeconds: 1,
                statsIntervalSeconds: 0,
                // Wide window, so every loss on a leg is one continuing outage.
                stabilitySeconds: 100_000
            )
        )
        let runTask = Task { try await session.run() }
        let advancer = Self.advancing(clock)
        defer { advancer.cancel() }

        _ = await eventually { flapping.starts.count == 1 && steady.starts.count == 1 }

        // The first leg spends its whole budget on repeated instant drops —
        // the rejected-stream-key shape — and dies.
        flapping.reportConnectionLost(reason: "closed")
        _ = await eventually { flapping.starts.count == 2 }
        flapping.reportConnectionLost(reason: "closed")
        _ = await eventually { flapping.starts.count == 3 }
        flapping.reportConnectionLost(reason: "closed")
        let flappingDied = await eventually {
            !events.named("stream.destination.lost", forDestination: "twitch").isEmpty
        }
        #expect(flappingDied)
        #expect(events.named("stream.reconnecting", forDestination: "twitch").count == 2)

        // The second leg's first loss now gets the policy's full budget — the
        // crux of per-leg state: it was never charged for the first leg's
        // outage.
        steady.reportConnectionLost(reason: "closed")
        let steadyRecovered = await eventually {
            !events.named("stream.reconnected", forDestination: "youtube").isEmpty
        }
        #expect(steadyRecovered)
        let attempts = events.named("stream.reconnecting", forDestination: "youtube")
            .compactMap { $0.params?["attempt"] }
        #expect(attempts == [.int(1)])

        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)
    }
}
