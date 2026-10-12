//
//  StreamHistoryFormatTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraHost

@testable import TingraApp

/// The stream history's wording: lengths, periods, formats, and destination
/// lists, pinned to a locale and a time zone of the test's own.
@Suite("StreamHistoryFormat")
struct StreamHistoryFormatTests {
    /// The locale the wording is pinned to.
    private let english = Locale(identifier: "en_US")

    /// The time zone the times are shown in.
    private let utc = TimeZone(identifier: "UTC") ?? .gmt

    /// 2026-10-11 15:04:00 UTC.
    private static let start = Date(timeIntervalSince1970: 1_791_731_040)

    /// A session starting at ``start``.
    private func entry(length: TimeInterval?, destinations: [String] = ["Twitch"]) -> StreamHistoryEntry {
        StreamHistoryEntry(
            number: 1,
            startedAt: Self.start,
            endedAt: length.map { Self.start.addingTimeInterval($0) },
            endReason: length == nil ? nil : .stopped,
            destinations: destinations,
            width: 1920,
            height: 1080,
            frameRate: 30
        )
    }

    /// Lengths in seconds and their wording; nonisolated because the test
    /// target defaults to the main actor and the arguments are read off it.
    private nonisolated static let lengths: [(seconds: Double, expected: String)] = [
        (0, "0s"),
        (42, "42s"),
        (59.6, "1m"),
        (125, "2m 5s"),
        (3963, "1h 6m 3s"),
        (30 * 3600, "30h"),
    ]

    @Test("a length reads in hours, minutes, and seconds, leaving out the zero parts", arguments: lengths)
    func duration(seconds: Double, expected: String) {
        #expect(StreamHistoryFormat.duration(seconds, locale: english) == expected)
    }

    @Test("a finished session's period names the day once, with both times")
    func finishedPeriod() {
        let text = StreamHistoryFormat.period(of: entry(length: 3960), locale: english, timeZone: utc)
        #expect(text.contains("Oct 11, 2026"))
        #expect(text.contains("3:04"))
        #expect(text.contains("4:10"))
        #expect(text.components(separatedBy: "2026").count == 2)
    }

    @Test("a session with no end reads as its start alone")
    func openPeriod() {
        let text = StreamHistoryFormat.period(of: entry(length: nil), locale: english, timeZone: utc)
        #expect(text.contains("Oct 11, 2026"))
        #expect(text.contains("3:04"))
        #expect(!text.contains("4:10"))
    }

    @Test("a session that ended the moment it started reads as its start alone")
    func zeroLengthPeriod() {
        let open = StreamHistoryFormat.period(of: entry(length: nil), locale: english, timeZone: utc)
        #expect(StreamHistoryFormat.period(of: entry(length: 0), locale: english, timeZone: utc) == open)
    }

    @Test("the program format reads as the status bar words it")
    func programFormat() {
        #expect(StreamHistoryFormat.programFormat(of: entry(length: 60)) == "1920×1080 · 30 fps")
    }

    @Test("destinations read as one list, and as nothing when none were recorded")
    func destinations() {
        #expect(StreamHistoryFormat.destinations(of: entry(length: 60), locale: english) == "Twitch")
        #expect(
            StreamHistoryFormat.destinations(
                of: entry(length: 60, destinations: ["Twitch", "YouTube"]), locale: english) == "Twitch and YouTube")
        #expect(StreamHistoryFormat.destinations(of: entry(length: 60, destinations: []), locale: english).isEmpty)
    }
}
