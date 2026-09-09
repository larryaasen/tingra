//
//  LogFileModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost

@testable import TingraApp

@Suite("LogFileModel")
struct LogFileModelTests {
    /// A log file in a fresh temporary folder, removed when the test ends.
    private struct Fixture {
        /// The folder.
        let folder = URL.temporaryDirectory.appending(path: "tingra-logmodel-\(UUID().uuidString)")

        /// The file under test.
        var logFile: LogFile { LogFile(url: folder.appending(path: "Tingra.log")) }

        /// Creates the folder.
        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        /// Writes the log's contents.
        func write(_ text: String) throws {
            try text.write(to: logFile.url, atomically: true, encoding: .utf8)
        }

        /// Removes the folder.
        func tearDown() { try? FileManager.default.removeItem(at: folder) }
    }

    /// Runs `body` against a fresh bus and returns every event it sent, in
    /// order, once the bus has drained.
    private func recordedEvents(during body: (EventBus) async -> Void) async -> [EventBusEvent] {
        let bus = EventBus()
        let stream = bus.events()
        await body(bus)
        bus.shutdown()
        var events: [EventBusEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("before the first refresh nothing is known; a refresh reads the size")
    func refreshReadsSize() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write("twelve bytes")
        let model = LogFileModel(logFile: fixture.logFile, eventBus: EventBus())
        #expect(model.byteCount == nil)
        #expect(!model.exists)
        #expect(model.isEmpty)

        model.refresh()

        #expect(model.byteCount == 12)
        #expect(model.exists)
        #expect(!model.isEmpty)
    }

    @Test("a missing file refreshes to no size, and an empty one to zero")
    func missingAndEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let model = LogFileModel(logFile: fixture.logFile, eventBus: EventBus())
        model.refresh()
        #expect(model.byteCount == nil)
        #expect(model.isEmpty)

        try fixture.write("")
        model.refresh()
        #expect(model.byteCount == 0)
        #expect(model.exists)
        #expect(model.isEmpty)
    }

    @Test("clearing empties the file, records log.cleared with the bytes it held, and re-reads the size")
    func clearRecordsAndRefreshes() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write("twelve bytes")
        var cleared: Bool?
        var model: LogFileModel?

        let events = await recordedEvents { bus in
            let logModel = LogFileModel(logFile: fixture.logFile, eventBus: bus)
            cleared = logModel.clear()
            model = logModel
        }

        #expect(cleared == true)
        #expect(model?.byteCount == 0)
        #expect(model?.clearFailure == nil)
        #expect(fixture.logFile.byteCount == 0)
        let event = try #require(events.first { $0.name == "log.cleared" })
        #expect(event.group == .event)
        #expect(event.domain == .platform)
        #expect(event.params == ["previousBytes": .int(12)])
        #expect(!events.contains { $0.name == "log.clear" })
    }

    @Test("clearing a missing file records zero bytes and no error")
    func clearMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let events = await recordedEvents { bus in
            let logModel = LogFileModel(logFile: fixture.logFile, eventBus: bus)
            #expect(logModel.clear())
            #expect(logModel.byteCount == nil)
        }

        #expect(events.first { $0.name == "log.cleared" }?.params == ["previousBytes": .int(0)])
    }

    @Test("a clear that cannot complete records a log.clear error and shows the reason")
    func clearRecordsError() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // A folder where the file should be: it exists, so the clear tries,
        // and a folder cannot be opened for writing, so it cannot complete.
        try FileManager.default.createDirectory(at: fixture.logFile.url, withIntermediateDirectories: true)
        var model: LogFileModel?

        let events = await recordedEvents { bus in
            let logModel = LogFileModel(logFile: fixture.logFile, eventBus: bus)
            #expect(!logModel.clear())
            model = logModel
        }

        let reason = try #require(model?.clearFailure)
        #expect(!reason.isEmpty)
        let event = try #require(events.first { $0.name == "log.clear" })
        #expect(event.group == .error)
        #expect(event.params?["error"] == .string(reason))
        #expect(!events.contains { $0.name == "log.cleared" })
    }

    @Test("a snapshot of a log with content is a dated copy")
    func snapshotCopies() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write("line\n")
        let model = LogFileModel(logFile: fixture.logFile, eventBus: EventBus())

        let snapshot = try #require(model.snapshot())
        defer { try? FileManager.default.removeItem(at: snapshot) }

        #expect(snapshot.lastPathComponent == LogFile.snapshotName(for: .now))
        #expect(try String(contentsOf: snapshot, encoding: .utf8) == "line\n")
        // Taking the snapshot also read the size.
        #expect(model.byteCount == 5)
    }

    @Test("a snapshot of a missing log is nil and records a log.snapshot error")
    func snapshotMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let events = await recordedEvents { bus in
            let logModel = LogFileModel(logFile: fixture.logFile, eventBus: bus)
            #expect(logModel.snapshot() == nil)
        }

        let event = try #require(events.first { $0.name == "log.snapshot" })
        #expect(event.group == .error)
        #expect(event.domain == .platform)
        #expect(event.params?["error"] == .string(LogFileError.empty(fixture.logFile.url).description))
    }
}
