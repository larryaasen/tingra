//
//  StreamSessionLiveStatisticsTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-01.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraHost

/// The live statistics readout and the window-summarized `stream.stats` it
/// brings: every live leg read once a second onto
/// ``StreamSession/liveStatistics``, the log line ten seconds after the start
/// and every interval after it, each summarizing its window (EVENTS.md,
/// "Stream statistics: the readout and the log").
@Suite("StreamSession live statistics")
struct StreamSessionLiveStatisticsTests {
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

    /// Builds a session with no media side, so the only clock subscriber is
    /// the statistics watcher (and a reconnect's wait) — each advance is then
    /// exactly one reading.
    ///
    /// - Parameters:
    ///   - legs: The destination legs.
    ///   - clock: The manually driven master clock.
    ///   - eventBus: The bus the session reports on.
    ///   - policy: The session policy under test.
    /// - Returns: The session.
    private static func makeSession(
        legs: [StreamSession.DestinationLeg],
        clock: ManualClock,
        eventBus: EventBus,
        policy: StreamSession.Policy
    ) -> StreamSession {
        StreamSession(
            programVideo: nil,
            programAudio: nil,
            destinations: legs,
            configuration: StreamConfiguration(),
            policy: policy,
            clock: clock,
            eventBus: eventBus
        )
    }

    /// Builds a counters snapshot.
    ///
    /// - Parameters:
    ///   - bytesSent: The cumulative bytes delivered.
    ///   - fps: The frame rate.
    /// - Returns: The snapshot, with an instantaneous rate the window
    ///   summary must not use.
    private static func counters(bytesSent: Int, fps: Int) -> StreamingStatistics {
        StreamingStatistics(bytesSent: bytesSent, bytesPerSecond: 1, framesPerSecond: fps)
    }

    /// Advances the clock to the given second and returns the reading it
    /// produced.
    ///
    /// - Parameters:
    ///   - second: The session-relative second to advance to (the session
    ///     starts at zero).
    ///   - clock: The master clock.
    ///   - iterator: The reader of the session's live statistics.
    /// - Returns: The reading, or nil when the readout finished.
    private static func reading(
        at second: Int,
        clock: ManualClock,
        from iterator: inout AsyncStream<[StreamSession.LegStatistics]>.Iterator
    ) async -> [StreamSession.LegStatistics]? {
        clock.advance(to: CMTime(value: CMTimeValue(second), timescale: 1))
        return await iterator.next()
    }

    @Test("The readout reads every live leg once a second and a log line summarizes each window")
    func readoutAndWindowSummary() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let session = Self.makeSession(
            legs: [try Self.makeLeg(id: "twitch", service: service)],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 3, liveStatistics: true, statsFirstWindowSeconds: 1)
        )
        var readout = session.liveStatistics.makeAsyncIterator()
        let runTask = Task { try await session.run() }
        #expect(await eventually { !events.named("stream.started").isEmpty && clock.subscriberCount == 1 })

        // With a one-second first window, the first reading closes it.
        service.setStatistics(Self.counters(bytesSent: 1000, fps: 30))
        let first = try #require(await Self.reading(at: 1, clock: clock, from: &readout))
        #expect(
            first == [
                StreamSession.LegStatistics(destination: "twitch", statistics: Self.counters(bytesSent: 1000, fps: 30))
            ])
        #expect(await eventually { events.named("stream.stats").count == 1 })
        let opening = try #require(events.named("stream.stats").first?.params)
        #expect(opening["destination"] == .string("twitch"))
        #expect(opening["elapsed"] == .double(1))
        #expect(opening["window"] == .double(1))
        #expect(opening["bytesSent"] == .int(1000))
        #expect(opening["bitrate"] == .int(8000))
        #expect(opening["fps"] == .int(30))
        #expect(opening["minFps"] == .int(30))

        // The next readings reach the readout without a log line…
        service.setStatistics(Self.counters(bytesSent: 3000, fps: 28))
        #expect(await Self.reading(at: 2, clock: clock, from: &readout)?.first?.statistics.framesPerSecond == 28)
        service.setStatistics(Self.counters(bytesSent: 6000, fps: 24))
        #expect(await Self.reading(at: 3, clock: clock, from: &readout)?.first?.statistics.bytesSent == 6000)
        #expect(events.named("stream.stats").count == 1)

        // …until the interval closes the window: 9000 bytes over 3 seconds,
        // the frame rates' average, and the dip the average hides.
        service.setStatistics(Self.counters(bytesSent: 10000, fps: 30))
        _ = await Self.reading(at: 4, clock: clock, from: &readout)
        #expect(await eventually { events.named("stream.stats").count == 2 })
        let summary = try #require(events.named("stream.stats").last?.params)
        #expect(summary["elapsed"] == .double(4))
        #expect(summary["window"] == .double(3))
        #expect(summary["bytesSent"] == .int(10000))
        #expect(summary["bitrate"] == .int(24000))
        #expect(summary["fps"] == .int(27))
        #expect(summary["minFps"] == .int(24))

        await session.stop()
        #expect(try await runTask.value == .stopRequested)
        // The readout finishes with the run.
        #expect(await readout.next() == nil)
    }

    @Test("The first log line comes ten seconds after the start and the next one interval after it")
    func logCadence() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let session = Self.makeSession(
            legs: [try Self.makeLeg(id: "twitch", service: MockStreamingService())],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 60, liveStatistics: true)
        )
        var readout = session.liveStatistics.makeAsyncIterator()
        let runTask = Task { try await session.run() }
        #expect(await eventually { !events.named("stream.started").isEmpty && clock.subscriberCount == 1 })

        var readings = 0
        for second in 1...131 {
            if await Self.reading(at: second, clock: clock, from: &readout) != nil {
                readings += 1
            }
        }
        #expect(readings == 131)
        #expect(await eventually { events.named("stream.stats").count == 3 })
        // The default first window is ten seconds: long enough for delivery
        // to settle before the log's first figures.
        #expect(StreamSession.Policy().statsFirstWindowSeconds == 10)
        let elapsed = events.named("stream.stats").compactMap { $0.params?["elapsed"] }
        #expect(elapsed == [.double(10), .double(70), .double(130)])
        #expect(events.named("stream.stats").first?.params?["window"] == .double(10))
        #expect(events.named("stream.stats").last?.params?["window"] == .double(60))

        await session.stop()
        _ = try await runTask.value
    }

    @Test("A counter that restarts after a reconnect counts as fresh delivery")
    func counterResetCountsAsDelivery() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let session = Self.makeSession(
            legs: [try Self.makeLeg(id: "twitch", service: service)],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 2, liveStatistics: true, statsFirstWindowSeconds: 1)
        )
        var readout = session.liveStatistics.makeAsyncIterator()
        let runTask = Task { try await session.run() }
        #expect(await eventually { !events.named("stream.started").isEmpty && clock.subscriberCount == 1 })

        service.setStatistics(Self.counters(bytesSent: 5000, fps: 30))
        _ = await Self.reading(at: 1, clock: clock, from: &readout)
        // A fresh connection: the counter starts again from zero.
        service.setStatistics(Self.counters(bytesSent: 2000, fps: 30))
        _ = await Self.reading(at: 2, clock: clock, from: &readout)
        service.setStatistics(Self.counters(bytesSent: 3000, fps: 30))
        _ = await Self.reading(at: 3, clock: clock, from: &readout)

        // 2000 bytes since the restart plus 1000 after it, over 2 seconds.
        #expect(await eventually { events.named("stream.stats").count == 2 })
        let summary = try #require(events.named("stream.stats").last?.params)
        #expect(summary["bitrate"] == .int(12000))
        #expect(summary["bytesSent"] == .int(3000))

        await session.stop()
        _ = try await runTask.value
    }

    @Test("A reconnecting leg leaves the readout while the others stay in it")
    func reconnectingLegLeavesReadout() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let steady = MockStreamingService()
        let flapping = MockStreamingService()
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: steady),
                try Self.makeLeg(id: "youtube", service: flapping),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(reconnectAttempts: 3, statsIntervalSeconds: 60, liveStatistics: true)
        )
        var readout = session.liveStatistics.makeAsyncIterator()
        let runTask = Task { try await session.run() }
        #expect(await eventually { !events.named("stream.started").isEmpty && clock.subscriberCount == 1 })

        let both = try #require(await Self.reading(at: 1, clock: clock, from: &readout))
        #expect(both.map(\.destination) == ["twitch", "youtube"])

        // Every attempt is refused, so the leg is still reconnecting at the
        // next reading whichever runs first.
        flapping.failNextStarts(with: [
            .connectionRejected("down"), .connectionRejected("down"), .connectionRejected("down"),
        ])
        flapping.reportConnectionLost(reason: "reset by peer")
        #expect(await eventually { !events.named("stream.reconnecting").isEmpty && clock.subscriberCount == 2 })

        let during = try #require(await Self.reading(at: 2, clock: clock, from: &readout))
        #expect(during.map(\.destination) == ["twitch"])

        await session.stop()
        _ = try await runTask.value
    }

    @Test("A lost leg leaves the readout and the log")
    func lostLegLeavesReadoutAndLog() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let steady = MockStreamingService()
        let dropped = MockStreamingService()
        let session = Self.makeSession(
            legs: [
                try Self.makeLeg(id: "twitch", service: steady),
                try Self.makeLeg(id: "youtube", service: dropped),
            ],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(
                reconnectAttempts: 0, statsIntervalSeconds: 1, liveStatistics: true, statsFirstWindowSeconds: 1)
        )
        var readout = session.liveStatistics.makeAsyncIterator()
        let runTask = Task { try await session.run() }
        #expect(await eventually { !events.named("stream.started").isEmpty && clock.subscriberCount == 1 })

        dropped.reportConnectionLost(reason: "reset by peer")
        #expect(await eventually { !events.named("stream.destination.lost", forDestination: "youtube").isEmpty })

        let after = try #require(await Self.reading(at: 1, clock: clock, from: &readout))
        #expect(after.map(\.destination) == ["twitch"])
        #expect(await eventually { !events.named("stream.stats", forDestination: "twitch").isEmpty })
        #expect(events.named("stream.stats", forDestination: "youtube").isEmpty)

        await session.stop()
        _ = try await runTask.value
    }

    @Test("A zero interval keeps the readout and writes no log line")
    func zeroIntervalKeepsReadout() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService(statistics: Self.counters(bytesSent: 500, fps: 30))
        let session = Self.makeSession(
            legs: [try Self.makeLeg(id: "twitch", service: service)],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 0, liveStatistics: true)
        )
        var readout = session.liveStatistics.makeAsyncIterator()
        let runTask = Task { try await session.run() }
        #expect(await eventually { !events.named("stream.started").isEmpty && clock.subscriberCount == 1 })

        for second in 1...3 {
            #expect(await Self.reading(at: second, clock: clock, from: &readout)?.count == 1)
        }
        #expect(events.named("stream.stats").isEmpty)

        await session.stop()
        _ = try await runTask.value
    }

    @Test("Without live statistics the readout stays empty and the log line is a single reading")
    func offByDefault() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService(
            statistics: StreamingStatistics(bytesSent: 9000, bytesPerSecond: 500, framesPerSecond: 30)
        )
        let session = Self.makeSession(
            legs: [try Self.makeLeg(id: "twitch", service: service)],
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 5)
        )
        #expect(StreamSession.Policy().liveStatistics == false)
        let runTask = Task { try await session.run() }
        #expect(await eventually { !events.named("stream.started").isEmpty && clock.subscriberCount == 1 })

        clock.advance(to: CMTime(value: 5, timescale: 1))
        #expect(await eventually { !events.named("stream.stats").isEmpty })
        let stats = try #require(events.named("stream.stats").first?.params)
        // The instantaneous rate, exactly as CLI.md defines the CLI's line.
        #expect(stats["bitrate"] == .int(4000))
        #expect(stats["minFps"] == nil)
        #expect(stats["window"] == nil)

        await session.stop()
        _ = try await runTask.value
        var readings = 0
        for await _ in session.liveStatistics {
            readings += 1
        }
        #expect(readings == 0)
    }
}
