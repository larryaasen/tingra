//
//  WatchAndSinkTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraHost

@testable import TingraCLI

/// Builds one real bus event by sending it through a fresh bus — the same
/// shape the capture plug-in emits, without a public memberwise init.
private func makeEvent(
    group: EventGroup,
    name: String,
    params: [String: EventValue]?
) async -> EventBusEvent? {
    let bus = EventBus()
    let events = bus.events()
    bus.send(group, domain: .capture, name: name, params: params)
    bus.shutdown()
    for await event in events {
        return event
    }
    return nil
}

/// A device event fixture in the exact shape the capture plug-in emits.
private func deviceEvent(name: String, kind: String) async -> EventBusEvent? {
    await makeEvent(
        group: .event,
        name: name,
        params: ["id": .string("0x1"), "name": .string("Some Device"), "kind": .string(kind)]
    )
}

@Suite("devices --watch event filtering")
struct DeviceEventFilterTests {
    @Test("--type all passes both kinds")
    func allPassesEverything() async throws {
        let filter = Devices.deviceEventFilter(for: .all)
        #expect(filter(try #require(await deviceEvent(name: "device.connected", kind: "camera"))))
        #expect(filter(try #require(await deviceEvent(name: "device.disconnected", kind: "microphone"))))
    }

    @Test("--type camera passes cameras and drops microphones, matching the listing filter")
    func cameraFiltersLikeListing() async throws {
        let filter = Devices.deviceEventFilter(for: .camera)
        #expect(filter(try #require(await deviceEvent(name: "device.connected", kind: "camera"))))
        #expect(!filter(try #require(await deviceEvent(name: "device.connected", kind: "microphone"))))
    }

    @Test("--type mic passes microphones and drops cameras")
    func micFiltersLikeListing() async throws {
        let filter = Devices.deviceEventFilter(for: .mic)
        #expect(!filter(try #require(await deviceEvent(name: "device.disconnected", kind: "camera"))))
        #expect(filter(try #require(await deviceEvent(name: "device.disconnected", kind: "microphone"))))
    }

    @Test("non-device events pass through every type filter — errors must never be silenced")
    func nonDeviceEventsAlwaysPass() async throws {
        let errorEvent = try #require(await makeEvent(group: .error, name: "input.resolve", params: nil))
        #expect(Devices.deviceEventFilter(for: .camera)(errorEvent))
        #expect(Devices.deviceEventFilter(for: .mic)(errorEvent))
    }
}

@Suite("ConsoleSink per-event refinement")
struct ConsoleSinkFilterTests {
    @Test("the refinement drops events after the group filter admits them")
    func refinementDropsEvents() async throws {
        let collected = Mutex<[String]>([])
        let sink = ConsoleSink(
            mode: .json,
            groups: [.event],
            isIncluded: { $0.name.hasPrefix("device.") },
            emit: { line in collected.withLock { $0.append(line) } }
        )

        await sink.receive(try #require(await deviceEvent(name: "device.connected", kind: "camera")))
        await sink.receive(try #require(await makeEvent(group: .event, name: "plugin.activated", params: nil)))

        let lines = collected.withLock { $0 }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("device.connected") == true)
    }
}
