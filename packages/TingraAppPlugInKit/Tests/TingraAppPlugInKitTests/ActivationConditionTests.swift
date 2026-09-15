//
//  ActivationConditionTests.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus

@testable import TingraAppPlugInKit

/// An activation condition: its manifest form, what it matches, and how it
/// travels through Codable as one string.
@Suite("Activation condition")
struct ActivationConditionTests {
    /// A bus event with a name and params.
    private func event(_ name: String, params: [String: EventValue]? = nil) -> EventBusEvent {
        EventBusEvent(date: .now, group: .event, domain: .capture, name: name, params: params, from: "test")
    }

    @Test("a bare event name parses without a qualifier")
    func parsesBareEvent() throws {
        let condition = try ActivationCondition(parsing: "stream.started")
        #expect(condition.event == "stream.started")
        #expect(condition.qualifier == nil)
        #expect(condition.rawValue == "stream.started")
        #expect(condition.description == "stream.started")
    }

    @Test("a qualified condition parses its key and value")
    func parsesQualifier() throws {
        let condition = try ActivationCondition(parsing: "device.connected:kind=camera")
        #expect(condition.event == "device.connected")
        #expect(condition.qualifier == ActivationCondition.Qualifier(key: "kind", value: "camera"))
        #expect(condition.rawValue == "device.connected:kind=camera")
        let withEquals = try ActivationCondition(parsing: "x.y:url=a=b")
        #expect(withEquals.qualifier == ActivationCondition.Qualifier(key: "url", value: "a=b"))
    }

    @Test("an empty or malformed event name throws")
    func throwsForInvalidEvent() {
        #expect(throws: ActivationConditionError.invalidEvent("")) { try ActivationCondition(parsing: "") }
        #expect(throws: ActivationConditionError.invalidEvent(":kind=camera")) {
            try ActivationCondition(parsing: ":kind=camera")
        }
        #expect(throws: ActivationConditionError.invalidEvent("stream started")) {
            try ActivationCondition(parsing: "stream started")
        }
    }

    @Test("a qualifier without a key, a value, or an equals sign throws")
    func throwsForMalformedQualifier() {
        for text in ["device.connected:camera", "device.connected:=camera", "device.connected:kind=", "a.b:"] {
            #expect(throws: ActivationConditionError.malformedQualifier(text)) {
                try ActivationCondition(parsing: text)
            }
        }
    }

    @Test("a bare condition matches its event by name alone, whatever the params")
    func matchesByName() throws {
        let condition = try ActivationCondition(parsing: "stream.started")
        #expect(condition.matches(event("stream.started")))
        #expect(condition.matches(event("stream.started", params: ["fps": .int(30)])))
        #expect(!condition.matches(event("stream.stopped")))
        #expect(!condition.matches(event("stream.started.extra")))
    }

    @Test("a qualified condition matches the param's string form")
    func matchesByQualifier() throws {
        let camera = try ActivationCondition(parsing: "device.connected:kind=camera")
        #expect(camera.matches(event("device.connected", params: ["kind": .string("camera")])))
        #expect(!camera.matches(event("device.connected", params: ["kind": .string("display")])))
        #expect(!camera.matches(event("device.connected", params: ["name": .string("camera")])))
        #expect(!camera.matches(event("device.connected")))
        let second = try ActivationCondition(parsing: "stream.reconnecting:attempt=2")
        #expect(second.matches(event("stream.reconnecting", params: ["attempt": .int(2)])))
        #expect(!second.matches(event("stream.reconnecting", params: ["attempt": .int(3)])))
    }

    @Test("a condition round-trips through Codable as one string")
    func roundTrips() throws {
        let original = try ActivationCondition(parsing: "device.connected:kind=camera")
        let data = try JSONEncoder().encode([original])
        #expect(String(decoding: data, as: UTF8.self) == #"["device.connected:kind=camera"]"#)
        let decoded = try JSONDecoder().decode([ActivationCondition].self, from: data)
        #expect(decoded == [original])
        #expect(decoded.first != ActivationCondition(event: "device.connected"))
    }

    @Test("decoding a malformed condition throws a decoding error")
    func decodingMalformedThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ActivationCondition].self, from: Data(#"["a.b:nokey"]"#.utf8))
        }
    }

    @Test("each error names the condition and the fix")
    func errorsDescribe() {
        #expect(ActivationConditionError.invalidEvent("x y").description.contains("'x y'"))
        #expect(ActivationConditionError.malformedQualifier("a:b").description.contains("event:key=value"))
    }
}
