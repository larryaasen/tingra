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
}
