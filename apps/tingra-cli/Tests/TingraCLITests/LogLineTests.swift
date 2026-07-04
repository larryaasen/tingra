//
//  LogLineTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus

@testable import TingraCLI

@Suite("LogLevel")
struct LogLevelTests {
    @Test("groups map to their EVENTS.md default levels")
    func groupMapping() {
        #expect(LogLevel(group: .app) == .info)
        #expect(LogLevel(group: .event) == .info)
        #expect(LogLevel(group: .tap) == .info)
        #expect(LogLevel(group: .network) == .debug)
        #expect(LogLevel(group: .trace) == .debug)
        #expect(LogLevel(group: .error) == .error)
    }

    @Test("every level pads to the same fixed width")
    func fixedWidth() {
        #expect(LogLevel.info.padded == "INFO ")
        #expect(LogLevel.debug.padded == "DEBUG")
        #expect(LogLevel.error.padded == "ERROR")
        #expect(Set([LogLevel.info, .debug, .error].map(\.padded.count)) == [5])
    }
}

@Suite("LogLineFormatter")
struct LogLineFormatterTests {
    /// Decodes an event with a fully controlled date — the bus stamps
    /// `Date()` on send, so deterministic timestamp tests go through the
    /// Codable path instead.
    private func makeEvent(date: Date, group: String, params: String) throws -> EventBusEvent {
        let json = """
            {"date": \(date.timeIntervalSince1970), "group": "\(group)", "domain": "output", \
            "name": "stream.connect.timeout", "params": \(params), "from": "test"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(EventBusEvent.self, from: Data(json.utf8))
    }

    @Test("the full line: level, MM-DD-YYYY timestamp with milliseconds and zone, [SSSS], @, domain, name, params")
    func fullLineFormat() throws {
        // 2026-07-04 19:50:02.250 UTC is 15:50:02.250 EDT.
        let base = try Date("2026-07-04T19:50:02Z", strategy: .iso8601)
        let event = try makeEvent(
            date: base.addingTimeInterval(0.250),
            group: "error",
            params: #"{"attempt": 2}"#
        )
        let newYork = try #require(TimeZone(identifier: "America/New_York"))

        let line = LogLineFormatter(sessionID: 42, timeZone: newYork).line(for: event)

        #expect(line == "ERROR 07-04-2026 15:50:02.250 EDT [0042] @ output stream.connect.timeout attempt=2")
    }

    @Test("the session ID renders as four digits and wraps past 9999")
    func sessionIDRendering() throws {
        let event = try makeEvent(date: Date(timeIntervalSince1970: 0), group: "event", params: "null")
        let utc = try #require(TimeZone(identifier: "UTC"))

        #expect(LogLineFormatter(sessionID: 7, timeZone: utc).line(for: event).contains("[0007]"))
        #expect(LogLineFormatter(sessionID: 9999, timeZone: utc).line(for: event).contains("[9999]"))
        #expect(LogLineFormatter(sessionID: 10_001, timeZone: utc).line(for: event).contains("[0001]"))
    }

    @Test("an event without params ends at the name — no trailing space")
    func lineWithoutParams() throws {
        let event = try makeEvent(date: Date(timeIntervalSince1970: 0), group: "trace", params: "null")
        let utc = try #require(TimeZone(identifier: "UTC"))

        let line = LogLineFormatter(sessionID: 1, timeZone: utc).line(for: event)

        #expect(line == "DEBUG 01-01-1970 00:00:00.000 GMT [0001] @ output stream.connect.timeout")
    }
}

@Suite("LogSession")
struct LogSessionTests {
    /// A throwaway counter file for one test.
    private func makeCounterURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "tingra-log-session-\(UUID().uuidString)")
            .appending(path: "log-session-id")
    }

    @Test("the ID increments exactly once per call — one cold start, one new session")
    func incrementsPerColdStart() {
        let url = makeCounterURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(LogSession.increment(at: url) == 1)
        #expect(LogSession.increment(at: url) == 2)
        #expect(LogSession.increment(at: url) == 3)
    }

    @Test("the ID wraps back to four digits after 9999")
    func wrapsAtTenThousand() throws {
        let url = makeCounterURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "9999".write(to: url, atomically: true, encoding: .utf8)

        #expect(LogSession.increment(at: url) == 0)
        #expect(LogSession.increment(at: url) == 1)
    }

    @Test("a corrupt counter file restarts the sequence instead of failing")
    func corruptCounterRestarts() throws {
        let url = makeCounterURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not a number".write(to: url, atomically: true, encoding: .utf8)

        #expect(LogSession.increment(at: url) == 1)
    }
}
