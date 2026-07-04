//
//  EventBusTests.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraEventBus

@Suite("EventBus")
struct EventBusTests {
    @Test("a subscriber receives a sent event with its group, domain, and name intact")
    func subscriberReceivesEvent() async {
        let bus = EventBus()
        let events = bus.events()

        bus.send(.event, domain: .output, name: "stream.started", params: ["bitrate": 4500])

        var iterator = events.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.group == .event)
        #expect(received?.domain == .output)
        #expect(received?.name == "stream.started")
        #expect(received?.params?["bitrate"] == .int(4500))
    }

    @Test("multiple subscribers each receive the same event")
    func multipleSubscribersReceiveEvent() async {
        let bus = EventBus()
        let first = bus.events()
        let second = bus.events()

        bus.send(.app, domain: .platform, name: "app.launched")

        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        #expect(await firstIterator.next()?.name == "app.launched")
        #expect(await secondIterator.next()?.name == "app.launched")
    }

    @Test("sensitive param values are redacted before any sink sees them")
    func sensitiveParamsAreRedacted() async {
        let bus = EventBus()
        let events = bus.events()

        bus.send(
            .event,
            domain: .output,
            name: "stream.starting",
            params: [
                "streamKey": .string("live_verysecretvalue"),
                "password": .string("hunter2"),
                "url": .string("rtmp://localhost:1935/live"),
            ]
        )

        var iterator = events.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.params?["streamKey"] == .string(EventBus.redactedValue))
        #expect(received?.params?["password"] == .string(EventBus.redactedValue))
        #expect(received?.params?["url"] == .string("rtmp://localhost:1935/live"))
    }

    @Test("each per group convenience sends an event with the matching group")
    func convenienceMethodsSetGroup() async {
        let bus = EventBus()
        let events = bus.events()

        bus.app("app.launched", domain: .platform)
        bus.error("stream.connect.timeout", domain: .output)
        bus.event("stream.started", domain: .output)
        bus.network("connection.opened", domain: .output)
        bus.tap("button.go_live", domain: .control)
        bus.trace("registry.resolve", domain: .capture)

        var iterator = events.makeAsyncIterator()
        var groups: [EventGroup] = []
        for _ in 0..<6 {
            guard let received = await iterator.next() else { break }
            groups.append(received.group)
        }
        #expect(groups == [.app, .error, .event, .network, .tap, .trace])
    }

    @Test("a convenience method captures the original call site, not the bus internals")
    func convenienceCapturesCallSite() async {
        let bus = EventBus()
        let events = bus.events()

        bus.error("stream.connect.timeout", domain: .output)

        var iterator = events.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.from.contains("EventBusTests.swift") == true)
        #expect(received?.from.contains("EventBus.swift") == false)
    }

    @Test("the emitting call site is captured in the from field")
    func callSiteIsCaptured() async {
        let bus = EventBus()
        let events = bus.events()

        bus.send(.trace, domain: .platform, name: "trace.test")

        var iterator = events.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.from.contains("EventBusTests.swift") == true)
    }

    @Test("a terminated subscriber is cleaned up and remaining subscribers keep receiving")
    func terminatedSubscriberDoesNotAffectOthers() async {
        let bus = EventBus()
        let remaining = bus.events()

        // Subscribe and immediately drop the stream: deallocation terminates
        // the subscription, which must remove it from the bus.
        _ = bus.events()

        bus.send(.event, domain: .platform, name: "after.termination")

        var iterator = remaining.makeAsyncIterator()
        #expect(await iterator.next()?.name == "after.termination")
    }
}

@Suite("EventBusEvent")
struct EventBusEventTests {
    /// A fully populated event for round-trip and equality tests.
    private static func makeEvent(name: String = "stream.started") -> EventBusEvent {
        EventBusEvent(
            date: Date(timeIntervalSinceReferenceDate: 773_452_800),
            group: .event,
            domain: .output,
            name: name,
            params: ["bitrate": 4500],
            from: "EventBusTests.swift:makeEvent()"
        )
    }

    /// Builds event JSON with one key optionally omitted, for missing-field
    /// decoding tests.
    private static func eventJSON(omitting omitted: String? = nil) -> Data {
        let fields: [(key: String, json: String)] = [
            ("date", "773452800.0"),
            ("group", #""event""#),
            ("domain", #""output""#),
            ("name", #""stream.started""#),
            ("params", #"{"bitrate": 4500}"#),
            ("from", #""EventBusTests.swift:makeEvent()""#),
        ]
        let body =
            fields
            .filter { $0.key != omitted }
            .map { #""\#($0.key)": \#($0.json)"# }
            .joined(separator: ", ")
        return Data("{\(body)}".utf8)
    }

    @Test("round-trips through JSON encoding and decoding")
    func roundTrip() throws {
        let original = Self.makeEvent()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EventBusEvent.self, from: data)
        #expect(decoded == original)
    }

    @Test(
        "decoding throws when a required field is missing",
        arguments: ["date", "group", "domain", "name", "from"]
    )
    func decodingThrowsForMissingRequiredField(missingKey: String) {
        let data = Self.eventJSON(omitting: missingKey)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(EventBusEvent.self, from: data)
        }
    }

    @Test("an event without the optional params key decodes with nil params")
    func missingParamsDecodesAsNil() throws {
        let data = Self.eventJSON(omitting: "params")
        let decoded = try JSONDecoder().decode(EventBusEvent.self, from: data)
        #expect(decoded.params == nil)
        #expect(decoded.name == "stream.started")
    }

    @Test("events with the same fields are equal; a differing field makes them unequal")
    func equality() {
        #expect(Self.makeEvent() == Self.makeEvent())
        #expect(Self.makeEvent() != Self.makeEvent(name: "stream.stopped"))
    }

    @Test("EventGroup and EventDomain encode as bare JSON strings")
    func groupAndDomainEncodeAsBareStrings() throws {
        let group = try JSONEncoder().encode([EventGroup.error])
        #expect(String(decoding: group, as: UTF8.self) == #"["error"]"#)

        let domain = try JSONEncoder().encode([EventDomain.output])
        #expect(String(decoding: domain, as: UTF8.self) == #"["output"]"#)
    }
}

@Suite("EventValue")
struct EventValueTests {
    @Test("encodes as bare JSON values and round-trips through decoding")
    func roundTrip() throws {
        let original: [String: EventValue] = [
            "codec": .string("h264"),
            "bitrate": .int(4500),
            "fps": .double(29.97),
            "reconnecting": .bool(true),
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: EventValue].self, from: data)
        #expect(decoded == original)
    }

    @Test("a JSON boolean decodes as bool, not as a number")
    func booleanStaysBoolean() throws {
        let data = Data(#"{"flag": true}"#.utf8)
        let decoded = try JSONDecoder().decode([String: EventValue].self, from: data)
        #expect(decoded["flag"] == .bool(true))
    }

    @Test("a whole JSON number decodes as int, not widened to double")
    func integerStaysInteger() throws {
        let data = Data(#"{"count": 3}"#.utf8)
        let decoded = try JSONDecoder().decode([String: EventValue].self, from: data)
        #expect(decoded["count"] == .int(3))
    }

    @Test("decoding throws for a JSON value that is not a string, number, or boolean")
    func decodingThrowsForUnsupportedValue() {
        let data = Data(#"{"nested": {"inner": 1}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode([String: EventValue].self, from: data)
        }
    }

    @Test("literal params infer the matching EventValue case")
    func literalConformances() {
        let params: [String: EventValue] = [
            "codec": "h264",
            "bitrate": 4500,
            "fps": 29.97,
            "reconnecting": true,
        ]
        #expect(params["codec"] == .string("h264"))
        #expect(params["bitrate"] == .int(4500))
        #expect(params["fps"] == .double(29.97))
        #expect(params["reconnecting"] == .bool(true))
    }
}
