//
//  EngineResourcesTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import Synchronization
import Testing
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

/// A small observable model standing in for the engine model: one tracked
/// value and one the resource never reads.
@MainActor
@Observable
private final class Counter {
    /// What the resource renders.
    var count = 0

    /// What the resource ignores.
    var noise = 0
}

/// The model-backed resources: a resource re-renders and signals only when
/// something its snapshot read has changed, and the three documents the
/// app serves render from a fresh model with the contract's keys.
@Suite("Engine resources")
struct EngineResourcesTests {
    /// A resource rendering the counter's count.
    private func resource(over counter: Counter) -> ModelResource {
        ModelResource(uri: "tingra://counter", name: "counter", title: "Counter", description: "A count.") {
            .object(["count": .int(counter.count)])
        }
    }

    @Test("reading renders the snapshot on the main actor")
    func reads() async throws {
        let counter = Counter()
        counter.count = 3
        let value = try await resource(over: counter).read()
        #expect(value == .object(["count": .int(3)]))
    }

    @Test(
        "a change to what the snapshot reads signals once; a change to anything else, or to the same value, stays silent"
    )
    func signalsOnChange() async throws {
        let counter = Counter()
        let resource = resource(over: counter)
        let received = Mutex(0)
        let collecting = Task {
            for await _ in resource.changes() { received.withLock { $0 += 1 } }
        }
        // Let the tracking task arm itself before the first change.
        try await Task.sleep(for: .milliseconds(30))

        counter.noise += 1
        counter.count = 0
        try await Task.sleep(for: .milliseconds(30))
        #expect(received.withLock { $0 } == 0)

        counter.count = 1
        try await Task.sleep(for: .milliseconds(30))
        #expect(received.withLock { $0 } == 1)

        counter.count = 1
        try await Task.sleep(for: .milliseconds(30))
        #expect(received.withLock { $0 } == 1)
        #expect(try await resource.read() == .object(["count": .int(1)]))
        collecting.cancel()
        _ = await collecting.value
    }

    @Test("ending the change stream stops its tracking task")
    func stopsOnTermination() async throws {
        let counter = Counter()
        let stream = resource(over: counter).changes()
        let task = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value
        // A change after the stop reaches nobody, and nothing traps.
        counter.count = 5
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test("the three documents render from a fresh model with the contract's keys")
    func documentsRender() throws {
        let suiteName = "EngineResourcesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = EngineModel(
            monitor: SilentMonitor(), snapshotPreferences: SnapshotPreferences(defaults: defaults),
            recordingPreferences: RecordingPreferences(defaults: defaults))
        let resources = EngineResources.all(for: model)
        #expect(resources.map(\.uri) == ["tingra://session", "tingra://program", "tingra://inputs"])
        #expect(resources.map(\.name) == ["session", "program", "inputs"])

        let session = EngineResources.sessionValue(of: model)
        #expect(session["stream"]?["state"] == .string("idle"))
        #expect(session["stream"]?["destinations"] == .array([]))
        #expect(session["recording"]?["state"] == .string("idle"))
        #expect(session["recording"]?["path"] == nil)

        let program = EngineResources.programValue(of: model)
        #expect(program["presets"] == .array([]))
        #expect(program["activePreset"] == .null)
        #expect(program["shots"] == .array([]))
        #expect(program["programShot"] == .null)
        #expect(program["previewShot"] == .null)
        #expect(program["programInputs"] == .array([]))
        #expect(program["previewInputs"] == .array([]))
        #expect(program["fadedToBlack"] == .bool(false))

        let inputs = EngineResources.inputsValue(of: model)
        #expect(inputs["inputs"] == .array([]))
    }
}
