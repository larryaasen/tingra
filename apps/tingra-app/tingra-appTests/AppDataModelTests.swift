//
//  AppDataModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost

@testable import TingraApp

/// Exercises the Data settings pane's model: the inventory it exposes, and
/// what a removal reports on the bus.
@MainActor
@Suite("AppDataModel")
struct AppDataModelTests {
    /// Collects every event the bus carries while a body runs.
    private func recordedEvents(during body: (EventBus) async -> Void) async -> [EventBusEvent] {
        let bus = EventBus()
        let stream = bus.events()
        await body(bus)
        bus.shutdown()
        var events: [EventBusEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("the inventory is empty until refreshed, then lists every kind")
    func refreshFillsInventory() throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        let model = AppDataModel(store: fixture.store, eventBus: EventBus())
        #expect(model.items.isEmpty)

        model.refresh()

        #expect(model.items.map(\.kind) == AppDataKind.allCases)
        #expect(model.failures.isEmpty)
    }

    @Test("a removal reports what it removed as counts, refreshes the inventory, and returns true")
    func removalReportsCounts() async throws {
        let fixture = try AppDataFixture()
        defer { fixture.tearDown() }
        try fixture.store.projectStore.save(fixture.sampleProject)
        try fixture.secureStorage.setSecret("live_a", forAccount: "a")
        try fixture.secureStorage.setSecret("live_b", forAccount: "b")
        fixture.defaults.set("dark", forKey: "appearance.mode")
        var removed: Bool?
        var model: AppDataModel?

        let events = await recordedEvents { bus in
            let appData = AppDataModel(store: fixture.store, eventBus: bus)
            removed = appData.removeAll()
            model = appData
        }

        #expect(removed == true)
        #expect(model?.failures.isEmpty == true)
        #expect(model?.items.filter { !$0.isEmpty }.map(\.kind) == [])
        let event = try #require(events.first { $0.name == "appdata.removed" })
        #expect(event.group == .event)
        #expect(event.domain == .platform)
        #expect(event.params?["project"] == .int(1))
        #expect(event.params?["streamKeys"] == .int(2))
        #expect(event.params?["preferences"] == .int(1))
        #expect(event.params?["destinations"] == .int(0))
        #expect(event.params?["logSession"] == .int(0))
        #expect(event.params?["recordings"] == nil)
        // Counts only: no secret and no path of the operator's.
        for value in event.params?.values ?? [:].values {
            if case .string = value { Issue.record("unexpected string param \(value)") }
        }
        #expect(!events.contains { $0.name == "appdata.remove" })
    }

    @Test(
        "a kind that could not be removed is an error event naming the kind, is left out of the counts, and returns false"
    )
    func refusalIsReported() async throws {
        let fixture = try AppDataFixture(clearFailure: .keychain(-34018))
        defer { fixture.tearDown() }
        try fixture.store.projectStore.save(fixture.sampleProject)
        try fixture.secureStorage.setSecret("live_a", forAccount: "a")
        var removed: Bool?
        var model: AppDataModel?

        let events = await recordedEvents { bus in
            let appData = AppDataModel(store: fixture.store, eventBus: bus)
            removed = appData.removeAll()
            model = appData
        }

        #expect(removed == false)
        #expect(model?.failures.map(\.kind) == [.streamKeys])
        let error = try #require(events.first { $0.name == "appdata.remove" })
        #expect(error.group == .error)
        #expect(error.params?["kind"] == .string("streamKeys"))
        #expect(error.params?["error"] == .string(SecureStorageError.keychain(-34018).description))
        let event = try #require(events.first { $0.name == "appdata.removed" })
        #expect(event.params?["streamKeys"] == nil)
        #expect(event.params?["project"] == .int(1))
        // The inventory after the removal still shows the key that stayed.
        #expect(model?.items.first { $0.kind == .streamKeys }?.count == 1)
    }
}
