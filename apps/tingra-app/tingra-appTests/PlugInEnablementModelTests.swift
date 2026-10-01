//
//  PlugInEnablementModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-30.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraApp

/// Exercises the Plug-ins pane's toggles: what they read from and write to
/// `plug-ins.json`, and what they report on the bus.
@MainActor
@Suite("PlugInEnablementModel")
struct PlugInEnablementModelTests {
    /// A plug-in id the tests switch.
    private let fixture = PlugInID(rawValue: "com.example.fixture")

    /// A temporary folder holding the file, removed by the caller.
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "PlugInEnablementModelTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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

    @Test("with no file every plug-in is on and nothing is wrong")
    func missingFileIsAllOn() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PlugInEnablementModel(store: PlugInEnablementStore(directory: directory), eventBus: EventBus())

        model.refresh()

        #expect(model.isOn(fixture))
        #expect(!model.isCrashed(fixture))
        #expect(model.problem == nil)
        #expect(!model.isUnreadable)
    }

    @Test("turning a plug-in off writes the file and reports the change after the fact")
    func turnOffWritesAndReports() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlugInEnablementStore(directory: directory)
        var isOn: Bool?

        let events = await recordedEvents { bus in
            let model = PlugInEnablementModel(store: store, eventBus: bus)
            model.setOn(false, for: fixture)
            isOn = model.isOn(fixture)
        }

        #expect(isOn == false)
        #expect(try store.read().isDisabled(fixture))
        let event = try #require(events.first { $0.name == "plugin.enablementChanged" })
        #expect(event.group == .event)
        #expect(event.domain == .plugIn)
        #expect(event.params?["id"] == .string(fixture.rawValue))
        #expect(event.params?["enabled"] == .bool(false))
    }

    @Test("turning a crashed plug-in back on forgets the crash")
    func turnOnForgetsCrash() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlugInEnablementStore(directory: directory)
        try store.update {
            $0.recordCrash(
                CrashedPlugInBundle(
                    id: fixture, cdHash: "abc", path: "~/Fixture.tingraplugin", frontEnd: "Tingra", date: .now))
        }
        let model = PlugInEnablementModel(store: store, eventBus: EventBus())
        model.refresh()
        #expect(model.isCrashed(fixture))
        #expect(!model.isOn(fixture))

        model.setOn(true, for: fixture)

        #expect(model.isOn(fixture))
        #expect(!model.isCrashed(fixture))
        #expect(try store.read().crash(of: fixture) == nil)
    }

    @Test("an unreadable file is kept, reported, and never overwritten by a toggle")
    func unreadableFileIsKept() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlugInEnablementStore(directory: directory)
        let garbage = Data("not json".utf8)
        try garbage.write(to: store.fileURL)
        var problem: String?
        var isUnreadable = false

        let events = await recordedEvents { bus in
            let model = PlugInEnablementModel(store: store, eventBus: bus)
            model.refresh()
            model.setOn(false, for: fixture)
            problem = model.problem
            isUnreadable = model.isUnreadable
        }

        #expect(problem?.contains("plug-ins.json") == true)
        #expect(isUnreadable)
        #expect(try Data(contentsOf: store.fileURL) == garbage)
        let error = try #require(events.first { $0.name == "plugin.enablement" })
        #expect(error.group == .error)
        #expect(!events.contains { $0.name == "plugin.enablementChanged" })
    }

    @Test("a refresh after the file is repaired clears the problem")
    func repairedFileClearsProblem() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlugInEnablementStore(directory: directory)
        try Data("not json".utf8).write(to: store.fileURL)
        let model = PlugInEnablementModel(store: store, eventBus: EventBus())
        model.refresh()
        #expect(model.isUnreadable)

        try FileManager.default.removeItem(at: store.fileURL)
        model.refresh()

        #expect(model.problem == nil)
        #expect(!model.isUnreadable)
    }
}
