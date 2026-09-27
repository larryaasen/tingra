//
//  AppUptimeTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// The About pane's uptime: whole minutes under an hour, hours spelled out
/// then minutes above it, and nothing negative.
@Suite("AppUptime")
struct AppUptimeTests {
    /// The locale the wording is pinned to, so the expectations do not
    /// depend on the machine running the tests.
    private let english = Locale(identifier: "en_US")

    /// Running times in seconds and their wording, typed up front so the
    /// arithmetic in the literals does not load the type checker; nonisolated
    /// because the test target defaults to the main actor and the arguments
    /// are read off it.
    private nonisolated static let wordings: [(seconds: Int, expected: String)] = [
        (0, "0 min"),
        (59, "0 min"),
        (4 * 60, "4 min"),
        (43 * 60, "43 min"),
        (59 * 60 + 59, "59 min"),
        (60 * 60, "1 hour"),
        (103 * 60, "1 hour 43 min"),
        (120 * 60, "2 hours"),
        (29 * 3600 + 60, "29 hours 1 min"),
        (48 * 3600 + 5 * 60 + 30, "48 hours 5 min"),
    ]

    @Test(
        "an uptime is worded in minutes under an hour and hours then minutes above it",
        arguments: wordings
    )
    func wording(seconds: Int, expected: String) {
        #expect(AppUptime.text(for: .seconds(seconds), locale: english) == expected)
    }

    @Test("a negative running time reads as zero")
    func negativeReadsAsZero() {
        #expect(AppUptime.text(for: .seconds(-90), locale: english) == "0 min")
    }

    @Test("the uptime at a moment counts from the launch")
    func textAtMomentCountsFromLaunch() {
        let launch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let uptime = AppUptime(launchDate: launch)
        #expect(uptime.text(at: launch.addingTimeInterval(103 * 60 + 20), locale: english) == "1 hour 43 min")
        #expect(uptime.elapsed(at: launch.addingTimeInterval(90)) == .seconds(90))
    }

    @Test("a clock set back before the launch never yields a negative elapsed time")
    func elapsedNeverNegative() {
        let launch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let uptime = AppUptime(launchDate: launch)
        #expect(uptime.elapsed(at: launch.addingTimeInterval(-300)) == .zero)
        #expect(uptime.text(at: launch.addingTimeInterval(-300), locale: english) == "0 min")
    }

    @Test("uptimes compare equal for one launch and unequal for another")
    func equality() {
        let launch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(AppUptime(launchDate: launch) == AppUptime(launchDate: launch))
        #expect(AppUptime(launchDate: launch) != AppUptime(launchDate: launch.addingTimeInterval(1)))
    }
}
