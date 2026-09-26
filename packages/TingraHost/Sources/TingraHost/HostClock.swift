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
    /// (`T0 + n × duration`), per CLOCK.md's scheduler options. Late ticks
    /// are skipped, never burst — see ``tick(every:lateTicks:)``.
    ///
    /// Outline status: jitter vs. a dedicated thread is still to be decided
    /// by benchmark (CLOCK.md open question).
    public func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        tick(every: duration, lateTicks: .skip)
    }

    /// A `ContinuousClock`-based deadline loop with absolute deadlines
    /// (`T0 + n × duration`), delivering late ticks per `lateTicks`
    /// (CLOCK.md, "Late ticks").
    ///
    /// A tick can be late two ways, and ``LateTickPolicy/skip`` closes both:
    /// the scheduler itself wakes past later deadlines (the process was
    /// suspended, or the thread starved), which jumps the grid to the latest
    /// due deadline; or the consumer is slower than the interval, which the
    /// newest-only buffer absorbs so it finds one current tick waiting
    /// rather than a backlog. ``LateTickPolicy/catchUp`` delivers every
    /// deadline, in order, into an unbounded buffer — the tick is only a
    /// `CMTime`, so a backlog costs next to nothing to hold.
    ///
    /// - Parameters:
    ///   - duration: The tick interval.
    ///   - lateTicks: What a late consumer receives.
    /// - Returns: The tick stream, yielding each tick's master clock time.
    public func tick(every duration: CMTime, lateTicks: LateTickPolicy) -> AsyncStream<CMTime> {
        let skipsLateTicks: Bool =
            switch lateTicks {
            case .skip: true
            case .catchUp: false
            // A policy this build does not know: skipping is the clock's
            // documented default, and never floods a consumer.
            @unknown default: true
            }
        return AsyncStream(bufferingPolicy: skipsLateTicks ? .bufferingNewest(1) : .unbounded) { continuation in
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
                    if skipsLateTicks {
                        n = Self.latestDueTick(after: n, elapsed: ContinuousClock.now - start, interval: interval)
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

    /// The index of the tick to deliver when the scheduler wakes for tick
    /// `scheduled`: that tick itself when it woke on time, or the latest
    /// deadline already due when it woke past later ones — so a late wake
    /// yields one current tick instead of every deadline it slept through.
    ///
    /// - Parameters:
    ///   - scheduled: The tick index the scheduler slept until.
    ///   - elapsed: Time since the stream's start, measured on waking.
    ///   - interval: The tick interval.
    /// - Returns: The tick index to deliver, never less than `scheduled`.
    static func latestDueTick(after scheduled: Int, elapsed: Duration, interval: Duration) -> Int {
        guard interval > .zero else { return scheduled }
        let due = Int((elapsed / interval).rounded(.down))
        return max(scheduled, due)
    }
}
