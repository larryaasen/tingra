//
//  LateTickPolicy.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// What a tick stream does with deadlines that passed while its consumer (or
/// the scheduler itself) was running late — CLOCK.md, "Late ticks".
///
/// Video is forgiving and audio is not (CLOCK.md, design principle 3), so the
/// choice belongs to the consumer, not the clock: a program frame rendered
/// for a moment already gone is stale work, while a mix block skipped is a
/// hole in the program audio and samples left behind in every channel queue.
public enum LateTickPolicy: Sendable {
    /// Missed deadlines are dropped: a late consumer receives only the most
    /// recent due tick, stamped with that deadline's time, and the grid
    /// resumes from there. Ticks stay on the absolute `T0 + n × duration`
    /// grid and monotonic; a late stretch shows up as a gap. The program
    /// tick's rule — skip, never burst — and the default.
    case skip

    /// Every deadline is delivered, in order, however late: a consumer that
    /// fell behind receives the missed ticks back to back and catches up.
    /// For producers whose output must stay contiguous — the audio mix tick
    /// and synthesized audio, where consecutive blocks must abut.
    case catchUp
}
