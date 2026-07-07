//
//  ConsoleEventSinkTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization
import Testing
import TingraEventBus
import TingraHost

@testable import Tingra

@Suite("ConsoleEventSink")
struct ConsoleEventSinkTests {
    /// A fixed formatter so lines are deterministic and no log-session counter
    /// is read from disk during tests.
    private let formatter = LogLineFormatter(sessionID: 1, timeZone: .gmt)

    /// Drives a sink through a real bus and returns the lines it emitted,
    /// draining every buffered event before reading (the attach contract).
    private func lines(
        groups: Set<EventGroup> = ConsoleEventSink.defaultGroups,
        emitting: (EventBus) -> Void
    ) async -> [String] {
        let collected = Mutex<[String]>([])
        let sink = ConsoleEventSink(
            groups: groups,
            formatter: formatter,
            emit: { line in collected.withLock { $0.append(line) } }
        )
        let bus = EventBus()
        let task = bus.attach(sink)
        emitting(bus)
        bus.shutdown()
        await task.value
        return collected.withLock { $0 }
    }

    @Test("prints an included event's domain, name, and sorted params")
    func printsIncludedEvent() async {
        let lines = await lines {
            $0.event(
                "program.take",
                domain: .composition,
                params: ["shot": .string("pip"), "name": .string("PiP")]
            )
        }
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.contains("composition program.take"))
        // Params are sorted by key, so `name` precedes `shot`.
        #expect(line.contains("name=PiP shot=pip"))
        #expect(line.contains("INFO"))
    }

    @Test("labels an error event ERROR")
    func labelsErrorEvent() async {
        let lines = await lines {
            $0.error("program.take", domain: .composition, params: ["reason": .string("unknownShot")])
        }
        #expect(lines.count == 1)
        #expect(lines[0].contains("ERROR"))
        #expect(lines[0].contains("reason=unknownShot"))
    }

    @Test("drops events outside the printed groups")
    func dropsFilteredGroups() async {
        // `network` is not in the default groups, so nothing is emitted.
        let lines = await lines {
            $0.network("stream.bytes", domain: .output)
        }
        #expect(lines.isEmpty)
    }

    @Test("prints a tap event by default, unlike the CLI console sink's default filter")
    func printsTapEventByDefault() async {
        // The app has no `--verbose` flag to turn `tap` back on, so — unlike
        // the CLI — it must be on by default or button clicks are invisible.
        let lines = await lines {
            $0.tap("shot.switcher", domain: .composition, params: ["shot": .string("pip")])
        }
        #expect(lines.count == 1)
        #expect(lines[0].contains("INFO"))
        // Tap events render `tap=>name - {key: value}`, domain omitted.
        #expect(lines[0].hasSuffix("tap=>shot.switcher - {shot: pip}"))
    }

    @Test("omits the trailing params when an event carries none")
    func omitsEmptyParams() async {
        let lines = await lines {
            $0.event("program.stopped", domain: .composition)
        }
        #expect(lines.count == 1)
        #expect(lines[0].hasSuffix("composition program.stopped"))
    }
}
