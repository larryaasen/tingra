//
//  ActivationTableTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraAppPlugInKit
import TingraEventBus
import TingraPlugInKit

@testable import TingraApp

/// The activation table: the conditions plug-ins declared, indexed by event
/// name, answering which plug-ins a bus event wakes.
@Suite("Activation table")
struct ActivationTableTests {
    /// A tally-light plug-in.
    private let tally = PlugInID(rawValue: "com.example.tally")

    /// A camera-watching plug-in.
    private let cameras = PlugInID(rawValue: "com.example.cameras")

    /// A bus event with a name and params.
    private func event(_ name: String, params: [String: EventValue]? = nil) -> EventBusEvent {
        EventBusEvent(date: .now, group: .event, domain: .output, name: name, params: params, from: "test")
    }

    /// A parsed condition.
    private func condition(_ text: String) throws -> ActivationCondition {
        try ActivationCondition(parsing: text)
    }

    @Test("an empty table matches nothing and says so")
    func emptyTable() {
        let table = ActivationTable()
        #expect(table.isEmpty)
        #expect(table.matches(event("stream.started")).isEmpty)
    }

    @Test("an event wakes the plug-ins whose conditions it meets, in registration order")
    func matchesInOrder() throws {
        var table = ActivationTable()
        table.add([try condition("stream.started")], for: tally)
        table.add([try condition("device.connected:kind=camera"), try condition("stream.started")], for: cameras)
        #expect(!table.isEmpty)
        let started = table.matches(event("stream.started"))
        #expect(started.map(\.plugIn) == [tally, cameras])
        #expect(started.map(\.condition.rawValue) == ["stream.started", "stream.started"])
        let camera = table.matches(event("device.connected", params: ["kind": .string("camera")]))
        let cameraCondition = try condition("device.connected:kind=camera")
        #expect(camera == [ActivationTable.Match(plugIn: cameras, condition: cameraCondition)])
        #expect(table.matches(event("device.connected", params: ["kind": .string("display")])).isEmpty)
        #expect(table.matches(event("stream.stopped")).isEmpty)
    }

    @Test("a plug-in with several conditions an event meets is woken once, by the first")
    func wakesOnce() throws {
        var table = ActivationTable()
        table.add([try condition("device.connected:kind=camera"), try condition("device.connected")], for: cameras)
        let matches = table.matches(event("device.connected", params: ["kind": .string("camera")]))
        #expect(matches.count == 1)
        #expect(matches.first?.condition.rawValue == "device.connected:kind=camera")
        let display = table.matches(event("device.connected", params: ["kind": .string("display")]))
        #expect(display.map(\.condition.rawValue) == ["device.connected"])
    }

    @Test("removing a plug-in drops its conditions and leaves the others")
    func removesPlugIn() throws {
        var table = ActivationTable()
        table.add([try condition("stream.started")], for: tally)
        table.add([try condition("stream.started"), try condition("device.connected")], for: cameras)
        table.removeAll(for: cameras)
        #expect(table.matches(event("stream.started")).map(\.plugIn) == [tally])
        #expect(table.matches(event("device.connected")).isEmpty)
        table.removeAll(for: tally)
        #expect(table.isEmpty)
    }
}
