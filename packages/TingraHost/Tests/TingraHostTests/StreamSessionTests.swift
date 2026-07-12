//
//  StreamSessionTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
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

/// Collects the events a session emits on the bus.
private final class CollectedEvents: Sendable {
    /// The events seen so far.
    private let events = Mutex<[EventBusEvent]>([])

    /// Consumes the bus's event stream into the collection.
    func consume(_ stream: AsyncStream<EventBusEvent>) -> Task<Void, Never> {
        Task {
            for await event in stream {
                events.withLock { $0.append(event) }
            }
        }
    }

    /// The events named `name`, in order.
    func named(_ name: String) -> [EventBusEvent] {
        events.withLock { $0.filter { $0.name == name } }
    }

    /// Every event collected so far.
    var all: [EventBusEvent] { events.withLock { $0 } }
}

@Suite("StreamSession")
struct StreamSessionTests {
    /// The destination sessions in this suite stream to.
    private static func makeDestination() throws -> Destination {
        Destination(
            url: try #require(URL(string: "rtmp://localhost:1935/live")),
            streamKey: "tingra_test_key"
        )
    }

    /// Builds a session over the given service and clock with a video and
    /// an audio stub input.
    private static func makeSession(
        service: MockStreamingService,
        clock: any EngineClock,
        eventBus: EventBus,
        policy: StreamSession.Policy,
        videoFrames: [CapturedFrame] = [],
        audioBuffers: [CapturedAudio] = []
    ) throws -> StreamSession {
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
            service: service,
            destination: try makeDestination(),
            configuration: StreamConfiguration(),
            policy: policy,
            clock: clock,
            eventBus: eventBus
        )
    }

    @Test("A running session delivers media on the session timeline and stops cleanly on request")
    func mediaFlowsAndStopsCleanly() async throws {
        let clock = ManualClock()
        clock.advance(to: CMTime(value: 10, timescale: 1))
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let pixelBuffer = try #require(makeTestPixelBuffer())
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 0),
            videoFrames: [
                CapturedFrame(
                    pixelBuffer: pixelBuffer,
                    presentationTime: CMTime(value: 105, timescale: 10)
                )
            ],
            audioBuffers: [
                try #require(makeTestAudio(pts: CMTime(value: 105, timescale: 10)))
            ]
        )
        let runTask = Task { try await session.run() }

        // T0 is read right after the service starts; the started event
        // marks it fixed at 10s.
        let started = await eventually { !events.named("stream.started").isEmpty }
        #expect(started)
        #expect(service.starts.count == 1)
        #expect(service.starts.first?.hadKey == true)

        // Audio passes through at capture cadence: 10.5s − T0 = 0.5s.
        let audioArrived = await eventually { !service.audioTimes.isEmpty }
        #expect(audioArrived)
        #expect(service.audioTimes.first == CMTime(value: 5, timescale: 10))

        // Video needs program ticks; every delivered frame carries a
        // tick-derived session-timeline PTS, at or after T0.
        let tickSeconds = Mutex(10.0)
        let videoArrived = await eventually {
            let next = tickSeconds.withLock { value in
                value += 0.1
                return value
            }
            clock.advance(to: CMTime(seconds: next, preferredTimescale: 600))
            return !service.videoTimes.isEmpty
        }
        #expect(videoArrived)
        let videoPTS = try #require(service.videoTimes.first)
        let lastTick = tickSeconds.withLock { $0 }
        #expect(videoPTS.seconds >= 0)
        #expect(videoPTS.seconds < lastTick - 10 + 0.2)

        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)
        #expect(service.stops == 1)
        // The bus delivers to the collector asynchronously; wait for the
        // final event to land before asserting on it.
        let stoppedArrived = await eventually { !events.named("stream.stopped").isEmpty }
        #expect(stoppedArrived)
        #expect(events.named("stream.stopped").first?.params?["reason"] == .string("stopRequested"))

        // The started params are the stream.plan names; the key never
        // appears in any param of any event.
        let startedParams = try #require(events.named("stream.started").first?.params)
        #expect(startedParams["url"] == .string("rtmp://localhost:1935/live"))
        #expect(startedParams["videoInput"] == .string("camera-1"))
        #expect(startedParams["audioInput"] == .string("mic-1"))
        for event in events.all {
            for (key, value) in event.params ?? [:] {
                if case .string(let string) = value, key != "url" {
                    #expect(!string.contains("tingra_test_key"))
                }
            }
        }
    }

    @Test("A program-source session delivers the compositor's frames on the session timeline and names them 'program'")
    func programSourceFlows() async throws {
        let clock = ManualClock()
        clock.advance(to: CMTime(value: 10, timescale: 1))
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let pixelBuffer = try #require(makeTestPixelBuffer())
        // The compositor's program frames arrive already tick-paced and
        // stamped on the master clock — the session consumes them as-is (no
        // ProgramPacer) and rebases each onto T0, exactly like the input path.
        let (programStream, continuation) = AsyncStream.makeStream(of: CapturedFrame.self)
        continuation.yield(
            CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: CMTime(value: 105, timescale: 10)))
        continuation.finish()

        let session = StreamSession(
            programVideo: programStream,
            programAudio: nil,
            service: service,
            destination: try Self.makeDestination(),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0),
            clock: clock,
            eventBus: eventBus
        )
        let runTask = Task { try await session.run() }

        let started = await eventually { !events.named("stream.started").isEmpty }
        #expect(started)

        // The program frame is delivered without advancing the clock — it is
        // pre-paced — and carries the T0 rebase: 10.5s − 10s = 0.5s.
        let videoArrived = await eventually { !service.videoTimes.isEmpty }
        #expect(videoArrived)
        #expect(service.videoTimes.first == CMTime(value: 5, timescale: 10))

        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)

        // A program source has no single device to name, so it reports the
        // stable "program" identity in the started params.
        let startedParams = try #require(events.named("stream.started").first?.params)
        #expect(startedParams["videoInput"] == .string("program"))
        #expect(startedParams["videoInputName"] == .string("Program"))
        #expect(startedParams["audioInput"] == nil)
    }

    @Test("A program-audio session delivers the mixer's blocks on the session timeline and names them 'mix'")
    func programAudioSourceFlows() async throws {
        let clock = ManualClock()
        clock.advance(to: CMTime(value: 10, timescale: 1))
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        // The mixer's program audio arrives already mix-tick-paced and
        // stamped on the master clock — the session consumes it as-is and
        // rebases each block onto T0, exactly like the pass-through path.
        let (programAudio, continuation) = AsyncStream.makeStream(of: CapturedAudio.self)
        continuation.yield(try #require(makeTestAudio(pts: CMTime(value: 105, timescale: 10))))
        continuation.finish()

        let session = StreamSession(
            programVideo: nil,
            programAudio: programAudio,
            service: service,
            destination: try Self.makeDestination(),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0),
            clock: clock,
            eventBus: eventBus
        )
        let runTask = Task { try await session.run() }

        let started = await eventually { !events.named("stream.started").isEmpty }
        #expect(started)

        // The block is delivered without advancing the clock — it is
        // pre-paced — and carries the T0 rebase: 10.5s − 10s = 0.5s.
        let audioArrived = await eventually { !service.audioTimes.isEmpty }
        #expect(audioArrived)
        #expect(service.audioTimes.first == CMTime(value: 5, timescale: 10))

        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)

        // The program mix has no single device to name, so it reports the
        // stable "mix" identity in the started params (GLOSSARY.md, "Mixer").
        let startedParams = try #require(events.named("stream.started").first?.params)
        #expect(startedParams["audioInput"] == .string("mix"))
        #expect(startedParams["audioInputName"] == .string("Mix"))
        #expect(startedParams["videoInput"] == nil)
    }

    @Test("The configured duration ends the session with durationElapsed")
    func durationElapses() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let service = MockStreamingService()
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 0, durationSeconds: 3)
        )
        let runTask = Task { try await session.run() }
        let advancer = Task {
            var seconds = 1.0
            while !Task.isCancelled {
                clock.advance(to: CMTime(seconds: seconds, preferredTimescale: 600))
                seconds += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { advancer.cancel() }

        let outcome = try await runTask.value
        #expect(outcome == .durationElapsed)
        #expect(service.stops == 1)
    }

    @Test("A connection loss reconnects within policy and the stream continues")
    func reconnectRecovers() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(
                reconnectAttempts: 2,
                reconnectDelaySeconds: 1,
                statsIntervalSeconds: 0
            )
        )
        let runTask = Task { try await session.run() }
        let advancer = Task {
            var seconds = 1.0
            while !Task.isCancelled {
                clock.advance(to: CMTime(seconds: seconds, preferredTimescale: 600))
                seconds += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { advancer.cancel() }

        _ = await eventually { service.starts.count == 1 }
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")

        let reconnected = await eventually { service.starts.count == 2 }
        #expect(reconnected)
        let recoveredEvent = await eventually { !events.named("stream.reconnected").isEmpty }
        #expect(recoveredEvent)
        let reconnecting = try #require(events.named("stream.reconnecting").first)
        #expect(reconnecting.params?["attempt"] == .int(1))
        #expect(reconnecting.params?["maxAttempts"] == .int(2))

        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)
    }

    @Test("Exhausting the reconnect attempts ends the session with connectionLost")
    func reconnectExhausts() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(
                reconnectAttempts: 2,
                reconnectDelaySeconds: 1,
                statsIntervalSeconds: 0
            )
        )
        let runTask = Task { try await session.run() }
        let advancer = Task {
            var seconds = 1.0
            while !Task.isCancelled {
                clock.advance(to: CMTime(seconds: seconds, preferredTimescale: 600))
                seconds += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { advancer.cancel() }

        _ = await eventually { service.starts.count == 1 }
        service.failNextStarts(with: [
            .connectionRejected("first attempt refused"),
            .connectionRejected("second attempt refused"),
        ])
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")

        let outcome = try await runTask.value
        #expect(outcome == .connectionLost)
        // The bus delivers to the collector asynchronously; wait for the
        // final event to land before asserting on the sequence.
        let stoppedArrived = await eventually { !events.named("stream.stopped").isEmpty }
        #expect(stoppedArrived)
        #expect(events.named("stream.reconnecting").count == 2)
        #expect(events.named("stream.reconnected").isEmpty)
        let stopped = try #require(events.named("stream.stopped").first)
        #expect(stopped.params?["reason"] == .string("connectionLost"))
    }

    @Test("Rapid repeated losses share one attempt budget and end with connectionLost")
    func rapidLossesShareOneBudget() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(
                reconnectAttempts: 2,
                reconnectDelaySeconds: 1,
                statsIntervalSeconds: 0,
                // Wide window so every loss in this test is the same outage.
                stabilitySeconds: 100_000
            )
        )
        let runTask = Task { try await session.run() }
        let advancer = Task {
            var seconds = 1.0
            while !Task.isCancelled {
                clock.advance(to: CMTime(seconds: seconds, preferredTimescale: 600))
                seconds += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { advancer.cancel() }

        // Every reconnect "succeeds" but the connection dies again at once
        // — the rejected-stream-key shape. The budget must not reset.
        _ = await eventually { service.starts.count == 1 }
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")
        _ = await eventually { service.starts.count == 2 }
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")
        _ = await eventually { service.starts.count == 3 }
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")

        let outcome = try await runTask.value
        #expect(outcome == .connectionLost)
        let attempts = events.named("stream.reconnecting").compactMap { $0.params?["attempt"] }
        #expect(attempts == [.int(1), .int(2)])
    }

    @Test("A loss after a stable stretch gets a fresh attempt budget")
    func stableRecoveryResetsBudget() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(
                reconnectAttempts: 1,
                reconnectDelaySeconds: 1,
                statsIntervalSeconds: 0,
                stabilitySeconds: 5
            )
        )
        let runTask = Task { try await session.run() }
        let advancer = Task {
            var seconds = 1.0
            while !Task.isCancelled {
                clock.advance(to: CMTime(seconds: seconds, preferredTimescale: 600))
                seconds += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { advancer.cancel() }

        _ = await eventually { service.starts.count == 1 }
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")
        let recovered = await eventually { service.starts.count == 2 }
        #expect(recovered)

        // Let the connection outlive the stability window, then drop it
        // again: the second outage gets the policy's full budget instead
        // of ending the session.
        let recoveryTime = clock.now
        _ = await eventually { CMTimeSubtract(clock.now, recoveryTime).seconds > 6 }
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")
        let recoveredAgain = await eventually { service.starts.count == 3 }
        #expect(recoveredAgain)
        #expect(events.named("stream.reconnected").count >= 1)

        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)
    }

    @Test("Reconnect disabled (0 attempts) ends the session on the first loss")
    func reconnectDisabled() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let service = MockStreamingService()
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(reconnectAttempts: 0, statsIntervalSeconds: 0)
        )
        let runTask = Task { try await session.run() }
        _ = await eventually { service.starts.count == 1 }
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")
        let outcome = try await runTask.value
        #expect(outcome == .connectionLost)
    }

    @Test("A rejected initial connection throws from run")
    func initialConnectionThrows() async throws {
        let clock = ManualClock()
        let service = MockStreamingService()
        service.failNextStarts(with: [.connectionRejected("refused")])
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: EventBus(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
        await #expect(throws: StreamingServiceError.connectionRejected("refused")) {
            _ = try await session.run()
        }
    }

    @Test("Stats events report the service's counters on the configured cadence")
    func statsEventsReportCounters() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService(
            statistics: StreamingStatistics(bytesSent: 9000, bytesPerSecond: 500, framesPerSecond: 30)
        )
        let session = try Self.makeSession(
            service: service,
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 5)
        )
        let runTask = Task { try await session.run() }
        let advancer = Task {
            var seconds = 1.0
            while !Task.isCancelled {
                clock.advance(to: CMTime(seconds: seconds, preferredTimescale: 600))
                seconds += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { advancer.cancel() }

        let statsArrived = await eventually { !events.named("stream.stats").isEmpty }
        #expect(statsArrived)
        let stats = try #require(events.named("stream.stats").first)
        #expect(stats.params?["bytesSent"] == .int(9000))
        #expect(stats.params?["bitrate"] == .int(4000))
        #expect(stats.params?["fps"] == .int(30))

        await session.stop()
        _ = try await runTask.value
    }
}
