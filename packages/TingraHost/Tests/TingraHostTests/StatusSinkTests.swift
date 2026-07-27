//
//  StatusSinkTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization
import Testing
import TingraEventBus

@testable import TingraHost

/// The status sink: retains the latest status-bearing events for point reads
/// and broadcasts them to subscribers — the source `stream_status` and the
/// MCP notifications draw from without polling.
@Suite("StatusSink")
struct StatusSinkTests {
    @Test("the latest event of a name supersedes the earlier one")
    func retainsLatestByName() async {
        let bus = EventBus()
        let sink = StatusSink()
        let attach = bus.attach(sink)

        bus.event("stream.stats", domain: .output, params: ["fps": .int(30)])
        bus.event("stream.stats", domain: .output, params: ["fps": .int(60)])

        let updated = await eventually {
            await sink.latestEvent(named: "stream.stats")?.params?["fps"] == .int(60)
        }
        #expect(updated)

        bus.shutdown()
        await attach.value
        await sink.shutdown()
    }

    @Test("each destination's latest event is retained separately")
    func retainsLatestPerDestination() async {
        let bus = EventBus()
        let sink = StatusSink()
        let attach = bus.attach(sink)

        // A fanned-out stream interleaves one stats event per leg per tick.
        // Keying by name alone would let the last leg's numbers stand in for
        // every destination's.
        bus.event("stream.stats", domain: .output, params: ["destination": .string("twitch"), "fps": .int(30)])
        bus.event("stream.stats", domain: .output, params: ["destination": .string("youtube"), "fps": .int(24)])
        bus.event("stream.stats", domain: .output, params: ["destination": .string("twitch"), "fps": .int(29)])

        let settled = await eventually {
            await sink.latestEvent(named: "stream.stats", forDestination: "twitch")?.params?["fps"] == .int(29)
        }
        #expect(settled)
        #expect(
            await sink.latestEvent(named: "stream.stats", forDestination: "youtube")?.params?["fps"] == .int(24)
        )
        #expect(await sink.latestEvent(named: "stream.stats", forDestination: "vimeo") == nil)
        #expect(await sink.latestEventsByDestination(named: "stream.stats").count == 2)
        // The name-only read is unchanged: the most recent, whichever leg.
        #expect(await sink.latestEvent(named: "stream.stats")?.params?["fps"] == .int(29))

        bus.shutdown()
        await attach.value
        await sink.shutdown()
    }

    @Test("an event with no destination is retained by name only")
    func eventsWithoutADestinationStayNameKeyed() async {
        let bus = EventBus()
        let sink = StatusSink()
        let attach = bus.attach(sink)

        bus.event("stream.started", domain: .output, params: ["url": .string("rtmp://localhost/live")])

        let landed = await eventually { await sink.latestEvent(named: "stream.started") != nil }
        #expect(landed)
        #expect(await sink.latestEventsByDestination(named: "stream.started").isEmpty)

        bus.shutdown()
        await attach.value
        await sink.shutdown()
    }

    @Test("non-status groups are not retained")
    func ignoresNonStatusGroups() async {
        let bus = EventBus()
        let sink = StatusSink()
        let attach = bus.attach(sink)

        bus.app("serve.started", domain: .control)
        bus.trace("engine.tick", domain: .platform)
        bus.event("stream.started", domain: .output)

        // The one event-group event lands; the app and trace events do not.
        let landed = await eventually { await sink.latestEvent(named: "stream.started") != nil }
        #expect(landed)
        #expect(await sink.latestEvent(named: "serve.started") == nil)
        #expect(await sink.latestEvent(named: "engine.tick") == nil)

        bus.shutdown()
        await attach.value
        await sink.shutdown()
    }

    @Test("error-group events are retained too")
    func retainsErrors() async {
        let bus = EventBus()
        let sink = StatusSink()
        let attach = bus.attach(sink)

        bus.error("stream.connection", domain: .output, params: ["identifier": .string("connectionLost")])

        let landed = await eventually { await sink.latestEvent(named: "stream.connection") != nil }
        #expect(landed)

        bus.shutdown()
        await attach.value
        await sink.shutdown()
    }

    @Test("updates broadcasts status events to a subscriber")
    func updatesBroadcasts() async {
        let bus = EventBus()
        let sink = StatusSink()
        let attach = bus.attach(sink)

        let received = Mutex<[String]>([])
        let updates = await sink.updates()
        let collector = Task {
            for await event in updates {
                received.withLock { $0.append(event.name) }
            }
        }

        // Re-emit until it is observed, tolerating the subscription starting
        // a beat after this task.
        let delivered = await eventually {
            bus.event("stream.started", domain: .output)
            return received.withLock { $0.contains("stream.started") }
        }
        #expect(delivered)

        collector.cancel()
        bus.shutdown()
        await attach.value
        await sink.shutdown()
    }
}
