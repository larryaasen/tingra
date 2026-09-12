//
//  LogWindowModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost

@testable import TingraApp

@Suite("LogWindowModel")
struct LogWindowModelTests {
    /// A log file in a fresh temporary folder and a defaults suite of its own,
    /// both removed when the test ends.
    private struct Fixture {
        /// The folder.
        let folder = URL.temporaryDirectory.appending(path: "tingra-logwindow-\(UUID().uuidString)")

        /// The defaults suite's name.
        let suiteName = "LogWindowModelTests-\(UUID().uuidString)"

        /// The defaults suite the filter choices persist in.
        let defaults: UserDefaults

        /// The file under test.
        var logFile: LogFile { LogFile(url: folder.appending(path: "Tingra.log")) }

        /// Creates the folder and the suite.
        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        /// Replaces the file with these lines.
        func write(_ lines: [String]) throws {
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: logFile.url)
        }

        /// Appends one line to the file, as the file sink does.
        func append(_ line: String) throws {
            let handle = try FileHandle(forWritingTo: logFile.url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        }

        /// A model over the file, stamped with log session 7.
        func model(bus: EventBus = EventBus(), chunkByteCount: Int = LogFile.chunkByteCount) -> LogWindowModel {
            LogWindowModel(
                logFile: logFile,
                eventBus: bus,
                preferences: LogWindowPreferences(defaults: defaults),
                sessionID: 7,
                chunkByteCount: chunkByteCount
            )
        }

        /// Removes the folder and the suite.
        func tearDown() {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// A log line in the human format.
    private static func line(_ number: Int, session: Int = 7, domain: String = "composition") -> String {
        let sessionText = session.formatted(.number.precision(.integerLength(4...)).grouping(.never))
        return " INFO 09-12-2026 10:00:00.000 EDT [\(sessionText)] @ \(domain) line.\(number) index=\(number)"
    }

    @Test("opening reads the file's last lines and attaches to the bus")
    func openReadsTail() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let written = [Self.line(1), Self.line(2), Self.line(3)]
        try fixture.write(written)
        let model = fixture.model()

        await model.open()

        #expect(model.lines.map(\.entry.text) == written)
        #expect(model.isAttached)
        #expect(!model.hasEarlierLines)
        #expect(model.readFailure == nil)
        #expect(!model.isLoading)
        model.close()
    }

    @Test("opening a missing file shows no lines and no failure")
    func openMissingFile() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let model = fixture.model()

        await model.open()

        #expect(model.lines.isEmpty)
        #expect(model.readFailure == nil)
        #expect(model.isAttached)
        model.close()
    }

    @Test("Load Earlier Lines prepends the lines before, in order, until the file's start")
    func loadEarlierReachesStart() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let written = (1...60).map { Self.line($0) }
        try fixture.write(written)
        let model = fixture.model(chunkByteCount: 300)

        await model.open()
        #expect(model.hasEarlierLines)
        var reads = 0
        while model.hasEarlierLines, reads < 100 {
            await model.loadEarlier()
            reads += 1
        }

        #expect(model.lines.map(\.entry.text) == written)
        #expect(!model.hasEarlierLines)
        #expect(Set(model.lines.map(\.id)).count == model.lines.count)
        model.close()
    }

    @Test("Load Earlier Lines does nothing while paused")
    func loadEarlierWhilePaused() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write((1...60).map { Self.line($0) })
        let model = fixture.model(chunkByteCount: 300)
        await model.open()
        let shown = model.lines

        model.pause()
        await model.loadEarlier()

        #expect(model.lines == shown)
        model.close()
    }

    @Test("events sent while the window is open arrive as the file sink's lines")
    func eventsArriveLive() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write([Self.line(1)])
        let bus = EventBus()
        let model = fixture.model(bus: bus)
        await model.open()

        bus.event("program.take", domain: .composition, params: ["shot": .string("pip")])
        bus.tap("cut.button", domain: .composition)
        bus.shutdown()
        await model.liveTask?.value

        #expect(model.lines.count == 3)
        let take = try #require(model.lines.dropFirst().first?.entry)
        #expect(take.name == "program.take")
        #expect(take.domain == "composition")
        #expect(take.sessionID == 7)
        #expect(take.text.hasSuffix("@ composition program.take shot=pip"))
        #expect(model.lines.last?.entry.isTap == true)
    }

    @Test("a log.cleared line empties the list, leaving the cleared line, as the file holds")
    func clearEmptiesList() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write((1...60).map { Self.line($0) })
        let bus = EventBus()
        let model = fixture.model(bus: bus, chunkByteCount: 300)
        await model.open()
        #expect(model.hasEarlierLines)

        bus.event(LogFileModel.clearedEventName, domain: .platform, params: ["previousBytes": .int(4096)])
        bus.shutdown()
        await model.liveTask?.value

        #expect(model.lines.count == 1)
        #expect(model.lines.first?.entry.name == "log.cleared")
        #expect(!model.hasEarlierLines)
    }

    @Test("a log.cleared name from another domain is an ordinary line")
    func clearFromOtherDomain() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write([Self.line(1)])
        let model = fixture.model()
        await model.open()

        model.receive(
            Self.line(2, domain: "com.example.plugin").replacing("line.2", with: "log.cleared"),
            attachment: model.attachment)

        #expect(model.lines.count == 2)
        model.close()
    }

    @Test("pausing detaches and freezes the list; resuming re-reads the file and re-attaches")
    func pauseAndResume() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write([Self.line(1)])
        let model = fixture.model()
        await model.open()

        model.pause()
        #expect(model.isPaused)
        #expect(!model.isAttached)
        try fixture.append(Self.line(2))
        #expect(model.lines.count == 1)

        await model.resume()
        #expect(!model.isPaused)
        #expect(model.isAttached)
        #expect(model.lines.map(\.entry.text) == [Self.line(1), Self.line(2)])
        model.close()
    }

    @Test("a line from an attachment that has ended is dropped")
    func staleAttachmentDropped() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let model = fixture.model()
        await model.open()
        let first = model.attachment
        model.pause()
        await model.resume()

        model.receive("stale", attachment: first)
        model.receive("current", attachment: model.attachment)

        #expect(model.lines.map(\.entry.text) == ["current"])
        model.close()
    }

    @Test("closing detaches and lets every loaded line go")
    func closeReleases() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write((1...60).map { Self.line($0) })
        let model = fixture.model(chunkByteCount: 300)
        await model.open()

        model.close()

        #expect(model.lines.isEmpty)
        #expect(!model.isAttached)
        #expect(!model.hasEarlierLines)
        #expect(!model.isPaused)
    }

    @Test("a file that cannot be read shows the reason and records a log.read error")
    func unreadableFile() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // A folder where the file should be: it exists, and cannot be read.
        try FileManager.default.createDirectory(at: fixture.logFile.url, withIntermediateDirectories: true)
        let bus = EventBus()
        let events = bus.events()
        let model = fixture.model(bus: bus)

        await model.open()
        let reason = try #require(model.readFailure)
        model.close()
        bus.shutdown()
        var sent: [EventBusEvent] = []
        for await event in events {
            sent.append(event)
        }

        #expect(!reason.isEmpty)
        let error = try #require(sent.first { $0.name == "log.read" })
        #expect(error.group == .error)
        #expect(error.domain == .platform)
        #expect(error.params?["error"] == .string(reason))
    }

    @Test("the live lines skip the ones the tail read already found, and only those")
    func liveLinesSkipOverlap() {
        #expect(Array(LogWindowModel.liveLines(["c", "d"], notIn: ["a", "b", "c"])) == ["d"])
        #expect(Array(LogWindowModel.liveLines(["b", "c"], notIn: ["a", "b", "c"])).isEmpty)
        #expect(Array(LogWindowModel.liveLines(["x", "y"], notIn: ["a", "b"])) == ["x", "y"])
        #expect(Array(LogWindowModel.liveLines(["x"], notIn: [])) == ["x"])
        #expect(Array(LogWindowModel.liveLines([], notIn: ["a"])).isEmpty)
        // A repeated identical line: one is in the file, the second still shows.
        #expect(Array(LogWindowModel.liveLines(["b", "b"], notIn: ["a", "b"])) == ["b"])
        // A live line matching a tail line that is not its last is not overlap.
        #expect(Array(LogWindowModel.liveLines(["a"], notIn: ["a", "b"])) == ["a"])
    }

    @Test("the domains are the loaded lines' distinct domains, sorted, and taps add none")
    func domainsFromLines() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write([
            Self.line(1, domain: "output"),
            Self.line(2, domain: "composition"),
            Self.line(3, domain: "output"),
            " INFO 09-12-2026 10:00:00.000 EDT [0007] @ tap=>cut.button",
        ])
        let model = fixture.model()
        await model.open()

        #expect(model.domains == ["composition", "output"])
        model.close()
    }

    @Test("the launch groups apply the filter")
    func launchGroupsFiltered() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write([Self.line(1, session: 6), Self.line(2), Self.line(3)])
        let model = fixture.model()
        await model.open()
        #expect(model.launchGroups.map(\.sessionID) == [6, 7])

        model.filter.launch = .current

        #expect(model.launchGroups.map(\.sessionID) == [7])
        #expect(model.launchGroups.first?.lines.count == 2)
        model.close()
    }

    @Test("the levels, taps, and launch choices persist; the domain and search do not")
    func filterPersistence() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let first = fixture.model()
        #expect(first.filter == LogWindowFilter())

        first.filter.levels = [.error]
        first.filter.showsTaps = false
        first.filter.launch = .current
        first.filter.domain = "output"
        first.filter.searchText = "timeout"

        #expect(fixture.model().filter == LogWindowFilter(levels: [.error], showsTaps: false, launch: .current))
    }
}
