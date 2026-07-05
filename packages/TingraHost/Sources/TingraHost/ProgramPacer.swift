//
//  ProgramPacer.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Synchronization
import TingraPlugInKit

/// The host's tick-paced latest-wins video pacing for the CLI era, before
/// composition exists (see CLOCK.md, "The tick before composition
/// exists").
///
/// The pacer consumes an input's frame stream into a latest-wins slot; on
/// each program tick it takes the most recent frame and restamps it with
/// the tick's master clock time — a one-layer composition with no
/// rendering. If no new frame arrived since the last tick, the previous
/// frame is re-sent with the new tick's time (a stalled input must not
/// stall the program); ticks before the first frame arrives send nothing.
/// When the Metal compositor lands (roadmap step 6) it replaces "take the
/// latest frame" with "render the layer tree" — the tick, the slot
/// semantics, and the timestamps do not change.
///
/// Ownership note (ARCHITECTURE.md, "Frame ownership across the `Input`
/// seam"): the pacer is the frame's one holder from the input's yield
/// until the next frame replaces it; re-sending across a stall re-reads
/// the held, immutable buffer, and downstream sinks must not retain a
/// frame beyond their append.
public struct ProgramPacer: Sendable {
    /// The clock whose tick paces the program (the master clock in
    /// production, a synthetic clock in tests — see CLOCK.md).
    private let clock: any EngineClock

    /// The program frame rate the tick fires at.
    private let frameRate: Int

    /// Creates a pacer.
    ///
    /// - Parameters:
    ///   - clock: The clock whose tick paces the program.
    ///   - frameRate: The program frame rate.
    public init(clock: any EngineClock, frameRate: Int) {
        self.clock = clock
        self.frameRate = frameRate
    }

    /// The program frame stream: one frame per program tick, restamped
    /// with the tick's master clock time, drawn latest-wins from `source`.
    ///
    /// The stream finishes when `source` finishes (the input stopped) or
    /// when the consumer terminates it.
    ///
    /// - Parameter source: The input's captured frames, at whatever
    ///   cadence the input natively produces.
    public func frames(from source: AsyncStream<CapturedFrame>) -> AsyncStream<CapturedFrame> {
        AsyncStream { continuation in
            let slot = FrameSlot()
            let clock = self.clock
            let frameRate = self.frameRate

            let fillTask = Task {
                for await frame in source {
                    slot.replace(with: frame)
                }
                slot.markSourceFinished()
            }

            let tickTask = Task {
                let tickDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                for await tickTime in clock.tick(every: tickDuration) {
                    let (latest, finished) = slot.current
                    if finished {
                        break
                    }
                    guard let latest else { continue }
                    continuation.yield(
                        CapturedFrame(pixelBuffer: latest.pixelBuffer, presentationTime: tickTime)
                    )
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                fillTask.cancel()
                tickTask.cancel()
            }
        }
    }
}

/// The pacer's latest-wins slot: the most recent frame the source has
/// produced, plus whether the source has finished. Mutex protected — the
/// fill task and the tick task touch it from different tasks. Holding a
/// frame here is the "one holder at a time" of the ownership rule; a
/// replaced frame is released as it is overwritten.
private final class FrameSlot: Sendable {
    /// The protected state: the latest frame and the source-finished flag.
    private struct State: Sendable {
        /// The most recent frame, nil before the first arrives.
        var latest: CapturedFrame?

        /// Whether the source stream has finished.
        var sourceFinished = false
    }

    /// The slot's state, Mutex protected.
    private let state = Mutex(State())

    /// Creates an empty slot.
    init() {}

    /// Replaces the held frame with a newer one (latest wins).
    func replace(with frame: CapturedFrame) {
        state.withLock { $0.latest = frame }
    }

    /// Records that the source stream has finished.
    func markSourceFinished() {
        state.withLock { $0.sourceFinished = true }
    }

    /// The held frame and the source-finished flag, read atomically.
    var current: (latest: CapturedFrame?, sourceFinished: Bool) {
        state.withLock { ($0.latest, $0.sourceFinished) }
    }
}
