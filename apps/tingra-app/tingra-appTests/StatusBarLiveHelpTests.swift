//
//  StatusBarLiveHelpTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// The Live reading's tooltip, pinned to a locale and a time zone of the
/// test's own.
@Suite("StatusBarView live tooltip")
@MainActor
struct StatusBarLiveHelpTests {
    /// The locale the wording is pinned to.
    private let english = Locale(identifier: "en_US")

    /// The time zone the time is shown in.
    private let utc = TimeZone(identifier: "UTC") ?? .gmt

    /// 2026-10-11 15:04:13 UTC.
    private let start = Date(timeIntervalSince1970: 1_791_731_053)

    /// A reading of the stream's delivery.
    private let stats = EngineModel.StreamStats(bitrateKbps: 164, fps: 32)

    @Test("the tooltip names the date and the time to the second the stream went on air, then the figures")
    func startAndFigures() {
        let lines = StatusBarView.liveHelp(startedAt: start, stats: stats, locale: english, timeZone: utc)
            .components(separatedBy: "\n")

        #expect(lines.count == 2)
        #expect(lines.first?.contains("Oct 11, 2026") == true)
        #expect(lines.first?.contains("3:04:13") == true)
        #expect(lines.last == "164 kbps · 32 fps")
    }

    @Test("before the first reading the tooltip is the start alone")
    func startAlone() {
        let text = StatusBarView.liveHelp(startedAt: start, stats: nil, locale: english, timeZone: utc)

        #expect(text.contains("Oct 11, 2026"))
        #expect(!text.contains("\n"))
        #expect(!text.contains("kbps"))
    }

    @Test("with no start known the tooltip is the figures alone")
    func figuresAlone() {
        #expect(
            StatusBarView.liveHelp(startedAt: nil, stats: stats, locale: english, timeZone: utc)
                == "164 kbps · 32 fps")
    }

    @Test("with neither known there is no tooltip")
    func empty() {
        #expect(StatusBarView.liveHelp(startedAt: nil, stats: nil, locale: english, timeZone: utc).isEmpty)
    }
}
