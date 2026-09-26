//
//  HostClockTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Testing
import TingraPlugInKit

@testable import TingraHost

@Suite("HostClock")
struct HostClockTests {
    @Test("now is monotonic across consecutive reads")
    func nowIsMonotonic() {
        let clock = HostClock()
        let first = clock.now
        let second = clock.now
        #expect(second >= first)
    }

    @Test("tick yields strictly increasing master clock times")
    func tickTimesIncrease() async {
        let clock = HostClock()
        // 1/100 s keeps the test fast; cadence accuracy is benchmark work
        // (CLOCK.md open question), so only ordering is asserted here.
        let ticks = clock.tick(every: CMTime(value: 1, timescale: 100))

        var received: [CMTime] = []
        for await time in ticks {
            received.append(time)
            if received.count == 3 { break }
        }

        #expect(received.count == 3)
        #expect(received[0] < received[1])
        #expect(received[1] < received[2])
    }

    @Test("a scheduler that wakes on time delivers the tick it slept until")
    func onTimeWakeDeliversScheduledTick() {
        let interval = Duration.milliseconds(10)
        #expect(HostClock.latestDueTick(after: 3, elapsed: .milliseconds(30), interval: interval) == 3)
        // Woken a hair early or late within the same interval: still that tick.
        #expect(HostClock.latestDueTick(after: 3, elapsed: .microseconds(29_999), interval: interval) == 3)
        #expect(HostClock.latestDueTick(after: 3, elapsed: .microseconds(39_999), interval: interval) == 3)
    }

    @Test("a scheduler that wakes past later deadlines jumps to the latest one due")
    func lateWakeJumpsToLatestDueTick() {
        let interval = Duration.milliseconds(10)
        #expect(HostClock.latestDueTick(after: 3, elapsed: .milliseconds(75), interval: interval) == 7)
        #expect(HostClock.latestDueTick(after: 1, elapsed: .seconds(7), interval: interval) == 700)
    }

    @Test("a zero interval never moves the grid")
    func zeroIntervalKeepsScheduledTick() {
        #expect(HostClock.latestDueTick(after: 5, elapsed: .seconds(1), interval: .zero) == 5)
    }

    @Test("a consumer that falls behind skips the missed ticks and resumes on the grid")
    func lateConsumerSkipsMissedTicks() async throws {
        let duration = CMTime(value: 1, timescale: 100)
        let ticks = HostClock().tick(every: duration, lateTicks: .skip)
        var iterator = ticks.makeAsyncIterator()

        let first = try #require(await iterator.next())
        // Fall behind by ~15 ticks.
        try await Task.sleep(for: .milliseconds(150))
        let second = try #require(await iterator.next())
        let third = try #require(await iterator.next())

        // Only the newest tick was waiting — not the one right after the
        // first — and every tick is still a whole number of intervals from
        // the first.
        #expect(intervals(from: first, to: second, every: duration) >= 5)
        #expect(intervals(from: second, to: third, every: duration) >= 1)
        #expect(isOnGrid(third, from: first, every: duration))
    }

    @Test("the default tick stream skips late ticks")
    func defaultTickStreamSkips() async throws {
        let duration = CMTime(value: 1, timescale: 100)
        var iterator = HostClock().tick(every: duration).makeAsyncIterator()

        let first = try #require(await iterator.next())
        try await Task.sleep(for: .milliseconds(150))
        let second = try #require(await iterator.next())

        #expect(intervals(from: first, to: second, every: duration) >= 5)
    }

    @Test("a catching-up consumer receives every tick it missed, in order")
    func catchingUpConsumerReceivesEveryTick() async throws {
        let duration = CMTime(value: 1, timescale: 100)
        var iterator = HostClock().tick(every: duration, lateTicks: .catchUp).makeAsyncIterator()

        let first = try #require(await iterator.next())
        try await Task.sleep(for: .milliseconds(150))
        var received: [CMTime] = []
        for _ in 0..<5 {
            received.append(try #require(await iterator.next()))
        }

        // Contiguous: the ticks right after the first, none skipped.
        for (offset, time) in received.enumerated() {
            #expect(intervals(from: first, to: time, every: duration) == offset + 1)
        }
    }
}

/// How many tick intervals separate two tick times, rounded to the nearest
/// whole interval (tick times sit exactly on the grid; rounding only absorbs
/// the `Double` conversion).
private func intervals(from start: CMTime, to end: CMTime, every duration: CMTime) -> Int {
    Int((CMTimeSubtract(end, start).seconds / duration.seconds).rounded())
}

/// Whether `time` sits a whole number of intervals from `start` — on the
/// absolute `T0 + n × duration` grid.
private func isOnGrid(_ time: CMTime, from start: CMTime, every duration: CMTime) -> Bool {
    let exact = CMTimeSubtract(time, start).seconds / duration.seconds
    return abs(exact - exact.rounded()) < 1e-6
}
