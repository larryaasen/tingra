//
//  EventSinkTests.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization
import Testing

@testable import TingraEventBus

/// A sink that collects every event it receives, for assertions.
private final class CollectingSink: EventSink {
    /// The received events, in delivery order. Mutex protected — the sink's
    /// consuming task appends while the test reads.
    private let storage = Mutex<[EventBusEvent]>([])

    func receive(_ event: EventBusEvent) async {
        storage.withLock { $0.append(event) }
    }

    /// The events received so far.
    var received: [EventBusEvent] {
        storage.withLock { $0 }
    }
}

@Suite("EventSink")
struct EventSinkTests {
    @Test("an attached sink receives every event in emission order, and shutdown drains what is buffered")
    func attachedSinkReceivesInOrder() async {
        let bus = EventBus()
        let sink = CollectingSink()
        let task = bus.attach(sink)

        bus.app("launch", domain: EventDomain("platform"))
        bus.event("stream.started", domain: EventDomain("output"))
        bus.error("stream.connect.timeout", domain: EventDomain("output"))

        bus.shutdown()
        await task.value

        #expect(sink.received.map(\.name) == ["launch", "stream.started", "stream.connect.timeout"])
    }

    @Test("events sent after shutdown go nowhere")
    func eventsAfterShutdownGoNowhere() async {
        let bus = EventBus()
        let sink = CollectingSink()
        let task = bus.attach(sink)

        bus.event("before", domain: EventDomain("output"))
        bus.shutdown()
        await task.value
        bus.event("after", domain: EventDomain("output"))

        #expect(sink.received.map(\.name) == ["before"])
    }

    @Test("detaching one sink leaves another attached and receiving")
    func detachingOneSinkLeavesAnother() async {
        let bus = EventBus()
        let detached = CollectingSink()
        let attached = CollectingSink()
        let detachedTask = bus.attach(detached)
        let attachedTask = bus.attach(attached)

        detachedTask.cancel()
        await detachedTask.value

        bus.event("stream.started", domain: EventDomain("output"))
        bus.shutdown()
        await attachedTask.value

        #expect(detached.received.isEmpty)
        #expect(attached.received.map(\.name) == ["stream.started"])
    }
}

@Suite("EventValue description")
struct EventValueDescriptionTests {
    @Test("each case renders as its bare value")
    func rendersBareValues() {
        #expect("\(EventValue.string("live"))" == "live")
        #expect("\(EventValue.int(4500))" == "4500")
        #expect("\(EventValue.double(29.97))" == "29.97")
        #expect("\(EventValue.bool(true))" == "true")
    }
}
