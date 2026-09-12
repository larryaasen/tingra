//
//  LogWindowSinkTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraHost

@testable import TingraApp

@Suite("LogWindowSink")
struct LogWindowSinkTests {
    @Test("every event, of every group, is delivered as the formatter's line, in order")
    func deliversFormattedLines() async {
        let formatter = LogLineFormatter(sessionID: 1, timeZone: .gmt)
        let delivered = Mutex<[String]>([])
        let bus = EventBus()
        let events = bus.events()
        let task = bus.attach(
            LogWindowSink(formatter: formatter) { line in
                delivered.withLock { $0.append(line) }
            })

        bus.event("program.take", domain: .composition, params: ["shot": .string("pip")])
        bus.tap("cut.button", domain: .composition)
        bus.network("stream.bytes", domain: .output)
        bus.trace("tick", domain: .composition)
        bus.error("stream.connect.timeout", domain: .output)
        bus.shutdown()
        await task.value
        var sent: [EventBusEvent] = []
        for await event in events {
            sent.append(event)
        }

        #expect(sent.count == 5)
        #expect(delivered.withLock { $0 } == sent.map(formatter.line(for:)))
    }
}
