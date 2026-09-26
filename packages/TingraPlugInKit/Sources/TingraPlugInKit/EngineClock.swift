//
//  EngineClock.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia

/// The master clock seam (see CLOCK.md).
///
/// Every timestamp in the engine is expressed against a single reference.
/// Components receive the clock by initializer injection — there is no
/// global "current clock" — so tests can substitute a synthetic clock and
/// drive the pipeline deterministically, with no hardware and no wall clock
/// waiting.
public protocol EngineClock: Sendable {
    /// The current master clock time.
    var now: CMTime { get }

    /// An absolute-deadline tick stream: each tick's deadline is computed as
    /// an absolute position on the master clock (`T0 + n × duration`), never
    /// `previous tick + interval`, so scheduling error cannot accumulate.
    /// Yields the tick's master clock time.
    ///
    /// Late ticks are **skipped**, never burst (``LateTickPolicy/skip``): a
    /// consumer that falls behind receives the most recent due tick, not
    /// every deadline it missed — the program tick's rule (CLOCK.md).
    func tick(every duration: CMTime) -> AsyncStream<CMTime>

    /// An absolute-deadline tick stream, as ``tick(every:)``, with the
    /// consumer choosing what happens to deadlines that pass while it is
    /// late: skipped, or delivered back to back so its output stays
    /// contiguous (``LateTickPolicy``).
    ///
    /// Added after ``tick(every:)`` with a default implementation that
    /// forwards to it, so a conformer that never runs late — a synthetic
    /// clock whose test scripts every tick — need not implement it.
    ///
    /// - Parameters:
    ///   - duration: The tick interval.
    ///   - lateTicks: What a late consumer receives.
    /// - Returns: The tick stream, yielding each tick's master clock time.
    func tick(every duration: CMTime, lateTicks: LateTickPolicy) -> AsyncStream<CMTime>
}

extension EngineClock {
    /// Forwards to ``tick(every:)``: a clock that does not distinguish late
    /// ticks treats both policies alike.
    ///
    /// - Parameters:
    ///   - duration: The tick interval.
    ///   - lateTicks: Ignored by this default.
    /// - Returns: The ``tick(every:)`` stream.
    public func tick(every duration: CMTime, lateTicks: LateTickPolicy) -> AsyncStream<CMTime> {
        tick(every: duration)
    }
}
