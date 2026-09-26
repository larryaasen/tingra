//
//  EngineClockTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Testing

@testable import TingraPlugInKit

/// A clock that implements only the original requirement, yielding a scripted
/// run of tick times — standing in for every synthetic test clock that
/// predates ``LateTickPolicy``.
private struct ScriptedClock: EngineClock {
    /// The times every tick stream yields, in order.
    let tickTimes: [CMTime]

    var now: CMTime { .zero }

    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { continuation in
            for time in tickTimes {
                continuation.yield(time)
            }
            continuation.finish()
        }
    }
}

/// Drains a tick stream into an array.
private func collect(_ stream: AsyncStream<CMTime>) async -> [CMTime] {
    var times: [CMTime] = []
    for await time in stream {
        times.append(time)
    }
    return times
}

@Suite("EngineClock")
struct EngineClockTests {
    @Test(
        "a clock implementing only tick(every:) serves both late-tick policies from it",
        arguments: [LateTickPolicy.skip, .catchUp]
    )
    func defaultPolicyTickForwardsToOriginalRequirement(policy: LateTickPolicy) async {
        let times = (0..<3).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let clock = ScriptedClock(tickTimes: times)

        let received = await collect(clock.tick(every: CMTime(value: 1, timescale: 30), lateTicks: policy))

        #expect(received == times)
    }
}
