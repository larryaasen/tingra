//
//  StreamHistoryModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost

@testable import TingraApp

/// The stream history's model: numbering, the session on air, what survives
/// a relaunch, clearing, and the events it reports.
@Suite("StreamHistoryModel")
struct StreamHistoryModelTests {
    /// A store in a fresh temporary folder, removed when the test ends.
    private struct Fixture {
        /// The folder, not yet on disk — a fresh install.
        let folder = URL.temporaryDirectory.appending(path: "tingra-streamhistorymodel-\(UUID().uuidString)")

        /// The store under test.
        var store: StreamHistoryStore { StreamHistoryStore(directory: folder) }

        /// Whether a file exists.
        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        /// Writes text where the history file goes.
        func writeRaw(_ text: String) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: store.fileURL, atomically: true, encoding: .utf8)
        }

        /// Removes the folder.
        func tearDown() { try? FileManager.default.removeItem(at: folder) }
    }

    /// A whole-second moment the sessions are timed from.
    private static let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// Runs `body` against a fresh bus and returns every event it sent, in
    /// order, once the bus has drained.
    private func recordedEvents(during body: (EventBus) async throws -> Void) async rethrows -> [EventBusEvent] {
        let bus = EventBus()
        let stream = bus.events()
        try await body(bus)
        bus.shutdown()
        var events: [EventBusEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// Starts a 1080p30 session to the given destinations.
    private func begin(_ model: StreamHistoryModel, _ destinations: [String] = ["Twitch"], after seconds: TimeInterval)
    {
        model.begin(
            destinations: destinations, width: 1920, height: 1080, frameRate: 30,
            at: Self.start.addingTimeInterval(seconds))
    }

    @Test("a fresh history is empty, with nothing on air and zeroed figures")
    func startsEmpty() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let model = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        #expect(model.isEmpty)
        #expect(model.history.activeNumber == nil)
        #expect(model.summary == StreamHistorySummary([]))
        #expect(!fixture.exists(fixture.store.fileURL))
    }

    @Test("a session going on air is session 1, on air, and already on disk")
    func beginRecordsAnOpenEntry() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let model = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        begin(model, ["Twitch", "YouTube"], after: 0)

        let entry = try #require(model.entries.first)
        #expect(entry.number == 1)
        #expect(entry.startedAt == Self.start)
        #expect(entry.endedAt == nil)
        #expect(entry.destinations == ["Twitch", "YouTube"])
        #expect(entry.width == 1920)
        #expect(entry.height == 1080)
        #expect(entry.frameRate == 30)
        #expect(model.history.activeNumber == 1)
        #expect(model.isOnAir(entry))
        #expect(try fixture.store.read() == model.entries)
    }

    @Test("ending the session stamps its end and reason, saves, and leaves nothing on air")
    func endClosesTheEntry() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let model = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        begin(model, after: 0)
        model.end(reason: .connectionLost, at: Self.start.addingTimeInterval(125))

        let entry = try #require(model.entries.first)
        #expect(entry.endedAt == Self.start.addingTimeInterval(125))
        #expect(entry.endReason == .connectionLost)
        #expect(entry.duration == 125)
        #expect(model.history.activeNumber == nil)
        #expect(!model.isOnAir(entry))
        #expect(try fixture.store.read() == model.entries)
    }

    @Test("ending with nothing on air changes nothing and writes nothing")
    func endWithoutSessionIsIgnored() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let model = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        model.end(reason: .stopped, at: Self.start)
        #expect(model.isEmpty)
        #expect(!fixture.exists(fixture.store.fileURL))
    }

    @Test("sessions number upward and the summary totals them")
    func numberingAndSummary() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let model = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        begin(model, after: 0)
        model.end(reason: .stopped, at: Self.start.addingTimeInterval(60))
        begin(model, after: 100)
        model.end(reason: .stopped, at: Self.start.addingTimeInterval(400))
        begin(model, after: 500)

        #expect(model.entries.map(\.number) == [1, 2, 3])
        #expect(model.summary.sessionCount == 3)
        #expect(model.summary.totalDuration == 360)
    }

    @Test("a second start closes the session still open, at the new start")
    func beginClosesAnOpenSession() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let model = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        begin(model, after: 0)
        begin(model, after: 90)

        #expect(model.entries.map(\.endedAt) == [Self.start.addingTimeInterval(90), nil])
        #expect(model.entries.first?.endReason == .stopped)
        #expect(model.history.activeNumber == 2)
    }

    @Test("a relaunch reads the history back, numbers on from it, and shows a session cut off as not on air")
    func relaunchContinues() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let first = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        begin(first, after: 0)

        let second = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        let cutOff = try #require(second.entries.first)
        #expect(cutOff.endedAt == nil)
        #expect(second.history.activeNumber == nil)
        #expect(!second.isOnAir(cutOff))

        begin(second, after: 1000)
        #expect(second.entries.map(\.number) == [1, 2])
        // The session cut off keeps no end: its length was never known.
        #expect(second.entries.first?.endedAt == nil)
        #expect(second.summary.totalDuration == 0)
    }

    @Test("marking the session on air saves its length, so a relaunch after a crash still totals it")
    func markOnAirSurvivesARelaunch() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let first = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        first.markOnAir(at: Self.start)
        #expect(!fixture.exists(fixture.store.fileURL))

        begin(first, after: 0)
        first.markOnAir(at: Self.start.addingTimeInterval(130))

        let second = StreamHistoryModel(store: fixture.store, eventBus: EventBus())
        let cutOff = try #require(second.entries.first)
        #expect(cutOff.endedAt == nil)
        #expect(cutOff.duration == 130)
        #expect(!second.isOnAir(cutOff))
        #expect(second.summary.totalDuration == 130)
    }

    @Test("clearing removes the file, empties the history, restarts the numbering, and reports the count")
    func clearRemovesEverything() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        var cleared: Bool?
        var model: StreamHistoryModel?

        let events = await recordedEvents { bus in
            let history = StreamHistoryModel(store: fixture.store, eventBus: bus)
            begin(history, after: 0)
            history.end(reason: .stopped, at: Self.start.addingTimeInterval(60))
            begin(history, after: 100)
            cleared = history.clear()
            begin(history, after: 200)
            model = history
        }

        #expect(cleared == true)
        #expect(model?.clearFailure == nil)
        #expect(model?.entries.map(\.number) == [1])
        let event = try #require(events.first { $0.name == "stream.history.cleared" })
        #expect(event.group == .event)
        #expect(event.domain == .platform)
        #expect(event.params?["sessions"] == .int(2))
    }

    @Test("a history that cannot be read is reported, set aside, and replaced by an empty one")
    func unreadableIsSetAside() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.writeRaw("{ not json")
        var model: StreamHistoryModel?

        let events = await recordedEvents { bus in
            model = StreamHistoryModel(store: fixture.store, eventBus: bus)
        }

        #expect(model?.isEmpty == true)
        let event = try #require(events.first { $0.name == "stream.history.load" })
        #expect(event.group == .error)
        #expect(event.domain == .platform)
        #expect(!fixture.exists(fixture.store.fileURL))
        #expect(try String(contentsOf: fixture.store.unreadableFileURL, encoding: .utf8) == "{ not json")
    }

    @Test("a history that cannot be written is reported and still shown")
    func unwritableIsReported() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        // A file where the folder should be, so the folder cannot be made.
        try "in the way".write(to: fixture.folder, atomically: true, encoding: .utf8)
        var model: StreamHistoryModel?

        let events = await recordedEvents { bus in
            let history = StreamHistoryModel(store: fixture.store, eventBus: bus)
            begin(history, after: 0)
            model = history
        }

        #expect(model?.entries.count == 1)
        let event = try #require(events.first { $0.name == "stream.history.save" })
        #expect(event.group == .error)
        // No folder path of the operator's reaches the log.
        if case .string(let message)? = event.params?["error"] {
            #expect(!message.contains(fixture.folder.deletingLastPathComponent().path(percentEncoded: false)))
        } else {
            Issue.record("the save error carries no message")
        }
    }
}
