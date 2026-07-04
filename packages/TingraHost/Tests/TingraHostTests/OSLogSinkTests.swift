//
//  OSLogSinkTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus
import os

@testable import TingraHost

@Suite("OSLogSink")
struct OSLogSinkTests {
    @Test("the group-to-level mapping follows the EVENTS.md table")
    func groupLevelMapping() {
        #expect(OSLogSink.level(for: .app) == .info)
        #expect(OSLogSink.level(for: .event) == .info)
        #expect(OSLogSink.level(for: .tap) == .info)
        #expect(OSLogSink.level(for: .network) == .debug)
        #expect(OSLogSink.level(for: .trace) == .debug)
        #expect(OSLogSink.level(for: .error) == .error)
    }

    @Test("params format as a key-sorted key=value list, one stable line per event")
    func paramsFormatSortedAndStable() {
        let formatted = OSLogSink.formatted([
            "fps": .int(30),
            "bitrate": .string("4500k"),
            "dropped": .double(0.5),
            "live": .bool(true),
        ])
        #expect(formatted == "bitrate=4500k dropped=0.5 fps=30 live=true")
    }

    @Test("empty params format as an empty string")
    func emptyParamsFormatEmpty() {
        #expect(OSLogSink.formatted([:]).isEmpty)
    }

    @Test("the subsystem is the Tingra identifier")
    func subsystemIsTingra() {
        #expect(OSLogSink.subsystem == "com.moonwink.tingra")
    }
}
