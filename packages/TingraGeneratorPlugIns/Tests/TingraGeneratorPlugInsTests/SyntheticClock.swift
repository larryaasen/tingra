//
//  SyntheticClock.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import TingraPlugInKit

/// A deterministic clock for tests, per CLOCK.md's substitution rule: the
/// tick stream yields exactly the scripted times, then finishes — no
/// hardware, no wall clock waiting.
struct SyntheticClock: EngineClock {
    /// The times the tick stream yields, in order.
    let tickTimes: [CMTime]

    /// When true, the tick stream never finishes after the scripted times,
    /// standing in for a live clock (used to test `stop()`).
    let staysOpen: Bool

    /// Creates a clock that yields `tickTimes` then finishes (or stays
    /// open when `staysOpen`).
    init(tickTimes: [CMTime] = [], staysOpen: Bool = false) {
        self.tickTimes = tickTimes
        self.staysOpen = staysOpen
    }

    /// The first scripted time, or zero — enough for tests, which drive
    /// everything through the tick stream.
    var now: CMTime { tickTimes.first ?? .zero }

    /// Yields the scripted times regardless of the requested duration; the
    /// generator under test decides the cadence, the test decides the
    /// timeline.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { continuation in
            for time in tickTimes {
                continuation.yield(time)
            }
            if !staysOpen {
                continuation.finish()
            }
        }
    }
}
