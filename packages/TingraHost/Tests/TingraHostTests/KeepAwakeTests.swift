//
//  KeepAwakeTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraHost

/// Tests that a stream session holds the Mac awake for exactly the length of
/// its run, on every way a run can end, and that the system-backed hold asks
/// for what CLOCK.md, "System sleep and App Nap" says a session needs.
@Suite("Keep awake")
struct KeepAwakeTests {
    /// Builds a one-destination session over the given service.
    private static func makeSession(
        service: MockStreamingService,
        eventBus: EventBus = EventBus(),
        keepAwake: (any KeepAwake)?
    ) throws -> StreamSession {
        StreamSession(
            videoInput: StubInput(id: "camera-1", name: "Stub Camera", kind: .camera),
            audioInput: nil,
            service: service,
            destination: Destination(
                url: try #require(URL(string: "rtmp://localhost:1935/live")), streamKey: "tingra_test_key"),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0),
            clock: ManualClock(),
            eventBus: eventBus,
            keepAwake: keepAwake
        )
    }

    @Test("A session holds the Mac awake while it runs and releases the hold when it stops")
    func heldForTheRun() async throws {
        let keepAwake = CountingKeepAwake()
        let service = MockStreamingService()
        let session = try Self.makeSession(service: service, keepAwake: keepAwake)
        let runTask = Task { try await session.run() }

        #expect(await eventually { service.starts.count == 1 })
        #expect(keepAwake.reasons == [StreamSession.keepAwakeReason])
        #expect(keepAwake.liveHolds == 1)

        await session.stop()
        _ = try await runTask.value
        #expect(keepAwake.liveHolds == 0)
        #expect(keepAwake.reasons.count == 1)
    }

    @Test("The hold is released when the session ends on a lost connection")
    func releasedOnConnectionLost() async throws {
        let keepAwake = CountingKeepAwake()
        let service = MockStreamingService()
        let session = StreamSession(
            videoInput: StubInput(id: "camera-1", name: "Stub Camera", kind: .camera),
            audioInput: nil,
            service: service,
            destination: Destination(
                url: try #require(URL(string: "rtmp://localhost:1935/live")), streamKey: "tingra_test_key"),
            configuration: StreamConfiguration(),
            policy: StreamSession.Policy(reconnectAttempts: 0, statsIntervalSeconds: 0),
            clock: ManualClock(),
            eventBus: EventBus(),
            keepAwake: keepAwake
        )
        let runTask = Task { try await session.run() }
        #expect(await eventually { service.starts.count == 1 })
        #expect(keepAwake.liveHolds == 1)

        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")
        #expect(try await runTask.value == .connectionLost)
        #expect(keepAwake.liveHolds == 0)
    }

    @Test("The hold is released when the session throws at start")
    func releasedWhenStartThrows() async throws {
        let keepAwake = CountingKeepAwake()
        let service = MockStreamingService()
        service.failNextStarts(with: [.connectionRejected("refused")])
        let session = try Self.makeSession(service: service, keepAwake: keepAwake)

        await #expect(throws: StreamingServiceError.connectionRejected("refused")) {
            try await session.run()
        }
        #expect(keepAwake.reasons.count == 1)
        #expect(keepAwake.liveHolds == 0)
    }

    @Test("The hold and its release are traced on the bus")
    func tracedOnTheBus() async throws {
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let session = try Self.makeSession(service: service, eventBus: eventBus, keepAwake: CountingKeepAwake())
        let runTask = Task { try await session.run() }
        #expect(await eventually { events.named("keepAwake.held").count == 1 })
        #expect(events.named("keepAwake.released").isEmpty)
        #expect(events.named("keepAwake.held").first?.group == .trace)

        await session.stop()
        _ = try await runTask.value
        #expect(await eventually { events.named("keepAwake.released").count == 1 })
    }

    @Test("A session given no keep-awake holds nothing and traces nothing")
    func nothingHeldWithoutOne() async throws {
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let session = try Self.makeSession(service: service, eventBus: eventBus, keepAwake: nil)
        let runTask = Task { try await session.run() }
        #expect(await eventually { service.starts.count == 1 })
        await session.stop()
        _ = try await runTask.value

        #expect(await eventually { !events.named("stream.stopped").isEmpty })
        #expect(events.named("keepAwake.held").isEmpty)
        #expect(events.named("keepAwake.released").isEmpty)
    }

    @Test("The system-backed hold keeps the Mac and its displays from idle sleep")
    func systemHoldOptions() {
        let options = ProcessActivityKeepAwake.options
        #expect(options.contains(.idleSystemSleepDisabled))
        #expect(options.contains(.idleDisplaySleepDisabled))
        #expect(options.contains(.latencyCritical))
    }

    @Test("A system-backed hold can be released more than once")
    func systemHoldReleasesOnce() {
        let hold = ProcessActivityKeepAwake().hold(reason: "Tingra keep-awake test")
        hold.release()
        hold.release()
    }
}
