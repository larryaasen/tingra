//
//  HostClock.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import TingraPlugInKit

/// The production `EngineClock`: the host time clock
/// (`CMClockGetHostTimeClock()`, backed by `mach_absolute_time`), which is
/// the reference captured frames already arrive in — zero clock domain
/// translation at the capture boundary (see CLOCK.md, "Why the host time
/// clock").
public struct HostClock: EngineClock {
    /// Creates the production clock. Stateless — every instance reads the
    /// same host time clock.
    public init() {}

    /// The current host time (see CLOCK.md, Timestamp rules).
    public var now: CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// A `ContinuousClock`-based deadline loop with absolute deadlines
    /// (`T0 + n × duration`), per CLOCK.md's scheduler options.
    ///
    /// Outline status: jitter vs. a dedicated thread is to be decided by
    /// benchmark (CLOCK.md open question), and dropped-tick behavior
    /// (skip, never burst) is not implemented yet — a loop that falls
    /// behind currently fires late ticks back to back.
    public func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                let t0 = now
                let interval = Duration.seconds(duration.seconds)
                var n = 1
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(until: start + interval * n, clock: .continuous)
                    } catch {
                        break
                    }
                    continuation.yield(t0 + CMTimeMultiply(duration, multiplier: Int32(n)))
                    n += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
