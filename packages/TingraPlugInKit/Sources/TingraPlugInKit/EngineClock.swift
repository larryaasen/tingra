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
    func tick(every duration: CMTime) -> AsyncStream<CMTime>
}
