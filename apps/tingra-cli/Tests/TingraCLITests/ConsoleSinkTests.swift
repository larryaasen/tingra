//
//  ConsoleSinkTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraHost

@testable import TingraCLI

/// Collects the lines a sink emits, in place of a real output stream.
private final class LineCollector: Sendable {
    /// The collected lines, in emission order. Mutex protected — the sink's
    /// consuming task appends while the test reads.
    private let storage = Mutex<[String]>([])

    /// Appends one emitted line.
    func append(_ line: String) {
        storage.withLock { $0.append(line) }
    }

    /// The lines collected so far.
    var lines: [String] {
        storage.withLock { $0 }
    }
}

/// Sends `send` on a fresh bus into a sink built by `makeSink`, drains, and
/// returns what the sink emitted.
private func emittedLines(
    makeSink: (@escaping @Sendable (String) -> Void) -> ConsoleSink,
    send: (EventBus) -> Void
) async -> [String] {
    let bus = EventBus()
    let collector = LineCollector()
    let task = bus.attach(makeSink { collector.append($0) })
    send(bus)
    bus.shutdown()
    await task.value
    return collector.lines
}

@Suite("ConsoleSink")
struct ConsoleSinkTests {
    @Test("the default filter prints app, error, and event; network, tap, and trace stay silent")
    func defaultFilterIsInfoLevel() async {
        let lines = await emittedLines(
            makeSink: { ConsoleSink(mode: .human, emit: $0) },
            send: { bus in
                bus.app("launch", domain: .platform)
                bus.error("stream.connect.timeout", domain: .output)
                bus.event("stream.started", domain: .output)
                bus.network("connect", domain: .output)
                bus.tap("go.live", domain: .control)
                bus.trace("input.discovered", domain: .capture)
            }
        )
        #expect(lines.count == 3)
        #expect(lines.contains { $0.contains("launch") })
        #expect(lines.contains { $0.contains("stream.connect.timeout") })
        #expect(lines.contains { $0.contains("stream.started") })
    }

    @Test("a custom group filter narrows what is printed")
    func customFilterNarrows() async {
        let lines = await emittedLines(
            makeSink: { ConsoleSink(mode: .human, groups: [.error], emit: $0) },
            send: { bus in
                bus.event("stream.started", domain: .output)
                bus.error("stream.connect.timeout", domain: .output)
            }
        )
        #expect(lines.count == 1)
        #expect(lines[0].contains("stream.connect.timeout"))
    }

    @Test("a human line carries level, session, domain, name, and sorted key=value params")
    func humanLineFormat() async {
        let lines = await emittedLines(
            makeSink: {
                ConsoleSink(mode: .human, formatter: LogLineFormatter(sessionID: 42), emit: $0)
            },
            send: { bus in
                bus.event("stream.started", domain: .output, params: ["fps": 30, "bitrate": .string("4500k")])
            }
        )
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix(" INFO "))
        #expect(lines[0].contains("[0042] @ "))
        #expect(lines[0].hasSuffix("@ output stream.started bitrate=4500k fps=30"))
    }

    @Test("a JSON line is one NDJSON record with the stable ts/group/domain/name/params keys")
    func jsonLineShape() async throws {
        let lines = await emittedLines(
            makeSink: { ConsoleSink(mode: .json, emit: $0) },
            send: { bus in
                bus.event("stream.started", domain: .output, params: ["bitrate": .string("4500k")])
            }
        )
        try #require(lines.count == 1)
        #expect(!lines[0].contains("\n"))
        for key in [#""ts""#, #""group""#, #""domain""#, #""name""#, #""params""#] {
            #expect(lines[0].contains(key))
        }
    }

    @Test("a JSON record round-trips through its stable keys")
    func jsonRecordRoundTrip() async throws {
        let lines = await emittedLines(
            makeSink: { ConsoleSink(mode: .json, emit: $0) },
            send: { bus in
                bus.error("stream.connect.timeout", domain: .output, params: ["attempt": 2])
            }
        )
        try #require(lines.count == 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ConsoleSink.JSONRecord.self, from: Data(lines[0].utf8))
        #expect(record.group == .error)
        #expect(record.domain == .output)
        #expect(record.name == "stream.connect.timeout")
        #expect(record.params?["attempt"] == .int(2))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let reencoded = String(decoding: try encoder.encode(record), as: UTF8.self)
        #expect(reencoded == lines[0])
    }

    @Test("bus-level redaction reaches the sink: a sensitive param prints as redacted")
    func sensitiveParamsArriveRedacted() async {
        let lines = await emittedLines(
            makeSink: { ConsoleSink(mode: .human, emit: $0) },
            send: { bus in
                bus.event("stream.started", domain: .output, params: ["streamKey": .string("live_secret")])
            }
        )
        #expect(lines.count == 1)
        #expect(!lines[0].contains("live_secret"))
        #expect(lines[0].contains(EventBus.redactedValue))
    }
}
