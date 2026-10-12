//
//  StreamHistoryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

/// The stream history's rules: numbering, the session on air, what a history
/// read back from disk means, and removal.
@Suite("StreamHistory")
struct StreamHistoryTests {
    /// The moment the sessions are timed from.
    private static let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// Starts a 1080p30 session.
    @discardableResult
    private func begin(
        _ history: inout StreamHistory, _ destinations: [String] = ["Twitch"], after seconds: TimeInterval
    ) -> StreamHistoryEntry {
        history.begin(
            destinations: destinations, width: 1920, height: 1080, frameRate: 30,
            at: Self.start.addingTimeInterval(seconds))
    }

    @Test("a new history is empty, with nothing on air and zeroed figures")
    func startsEmpty() {
        let history = StreamHistory()
        #expect(history.isEmpty)
        #expect(history.entries.isEmpty)
        #expect(history.activeNumber == nil)
        #expect(history.summary == StreamHistorySummary([]))
    }

    @Test("a session going on air is session 1, open, and on air")
    func beginAddsAnOpenEntry() {
        var history = StreamHistory()
        let entry = begin(&history, ["Twitch", "YouTube"], after: 0)

        #expect(history.entries == [entry])
        #expect(entry.number == 1)
        #expect(entry.startedAt == Self.start)
        #expect(entry.endedAt == nil)
        #expect(entry.endReason == nil)
        #expect(entry.destinations == ["Twitch", "YouTube"])
        #expect(entry.width == 1920)
        #expect(entry.height == 1080)
        #expect(entry.frameRate == 30)
        #expect(history.activeNumber == 1)
        #expect(history.isOnAir(entry))
        #expect(!history.isEmpty)
    }

    @Test("ending the session stamps its end and reason and leaves nothing on air")
    func endClosesTheEntry() throws {
        var history = StreamHistory()
        begin(&history, after: 0)
        let closed = history.end(reason: .connectionLost, at: Self.start.addingTimeInterval(125))

        let entry = try #require(history.entries.first)
        #expect(closed)
        #expect(entry.endedAt == Self.start.addingTimeInterval(125))
        #expect(entry.endReason == .connectionLost)
        #expect(entry.duration == 125)
        #expect(history.activeNumber == nil)
        #expect(!history.isOnAir(entry))
    }

    @Test("ending with nothing on air changes nothing and says so")
    func endWithoutSessionIsIgnored() {
        var history = StreamHistory()
        let closedNothing = history.end(reason: .stopped, at: Self.start)
        #expect(!closedNothing)
        begin(&history, after: 0)
        history.end(reason: .stopped, at: Self.start.addingTimeInterval(10))
        let before = history
        let closedAgain = history.end(reason: .appQuit, at: Self.start.addingTimeInterval(99))
        #expect(!closedAgain)
        #expect(history == before)
    }

    @Test("sessions number upward and the summary totals the finished ones")
    func numberingAndSummary() {
        var history = StreamHistory()
        begin(&history, after: 0)
        history.end(reason: .stopped, at: Self.start.addingTimeInterval(60))
        begin(&history, after: 100)
        history.end(reason: .stopped, at: Self.start.addingTimeInterval(400))
        begin(&history, after: 500)

        #expect(history.entries.map(\.number) == [1, 2, 3])
        #expect(history.summary.sessionCount == 3)
        #expect(history.summary.totalDuration == 360)
    }

    @Test("a second start closes the session still open, at the new start, as stopped")
    func beginClosesAnOpenSession() {
        var history = StreamHistory()
        begin(&history, after: 0)
        begin(&history, after: 90)

        #expect(history.entries.map(\.endedAt) == [Self.start.addingTimeInterval(90), nil])
        #expect(history.entries.first?.endReason == .stopped)
        #expect(history.activeNumber == 2)
    }

    @Test("a history read back has nothing on air, keeps a cut-off session open, and numbers on from it")
    func readBackContinues() throws {
        var first = StreamHistory()
        begin(&first, after: 0)

        var second = StreamHistory(entries: first.entries)
        let cutOff = try #require(second.entries.first)
        #expect(second.activeNumber == nil)
        #expect(!second.isOnAir(cutOff))

        begin(&second, after: 1000)
        #expect(second.entries.map(\.number) == [1, 2])
        // The session cut off keeps no end: its length was never known.
        #expect(second.entries.first?.endedAt == nil)
        #expect(second.summary.totalDuration == 0)
    }

    @Test("marking the session on air gives it a length before it has an end")
    func markOnAirGivesALength() throws {
        var history = StreamHistory()
        begin(&history, after: 0)
        let marked = history.markOnAir(at: Self.start.addingTimeInterval(70))

        let entry = try #require(history.entries.first)
        #expect(marked)
        #expect(entry.lastOnAirAt == Self.start.addingTimeInterval(70))
        #expect(entry.endedAt == nil)
        #expect(entry.duration == 70)
        #expect(history.isOnAir(entry))
        #expect(history.summary.totalDuration == 70)
    }

    @Test("a mark that is not later than the last one, or with nothing on air, changes nothing")
    func markOnAirIgnoresStaleAndIdle() {
        var history = StreamHistory()
        let idle = history.markOnAir(at: Self.start)
        #expect(!idle)

        begin(&history, after: 0)
        let atStart = history.markOnAir(at: Self.start)
        history.markOnAir(at: Self.start.addingTimeInterval(70))
        let earlier = history.markOnAir(at: Self.start.addingTimeInterval(10))
        #expect(!atStart)
        #expect(!earlier)
        #expect(history.entries.first?.lastOnAirAt == Self.start.addingTimeInterval(70))

        history.end(reason: .stopped, at: Self.start.addingTimeInterval(90))
        let afterEnd = history.markOnAir(at: Self.start.addingTimeInterval(130))
        #expect(!afterEnd)
        #expect(history.entries.first?.duration == 90)
    }

    @Test("a session cut off after a mark keeps the length it had reached and counts in the total")
    func cutOffSessionKeepsItsLength() throws {
        var first = StreamHistory()
        begin(&first, after: 0)
        first.markOnAir(at: Self.start.addingTimeInterval(130))

        let second = StreamHistory(entries: first.entries)
        let cutOff = try #require(second.entries.first)
        #expect(!second.isOnAir(cutOff))
        #expect(cutOff.endedAt == nil)
        #expect(cutOff.duration == 130)
        #expect(second.summary.totalDuration == 130)
    }

    @Test("removing everything empties the history and restarts the numbering")
    func removeAllRestarts() {
        var history = StreamHistory()
        begin(&history, after: 0)
        history.removeAll()
        #expect(history.isEmpty)
        #expect(history.activeNumber == nil)
        let next = begin(&history, after: 10)
        #expect(next.number == 1)
    }

    @Test("histories compare equal with the same sessions and state, and unequal otherwise")
    func equality() {
        var one = StreamHistory()
        var other = StreamHistory()
        #expect(one == other)
        begin(&one, after: 0)
        #expect(one != other)
        begin(&other, after: 0)
        #expect(one == other)
        // The same entries, but nothing on air: a history read back from disk.
        #expect(StreamHistory(entries: one.entries) != one)
    }
}
