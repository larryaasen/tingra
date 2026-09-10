//
//  StillFrameHolder.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Synchronization
import TingraPlugInKit

/// The frame plumbing shared by the inputs whose picture never changes —
/// the still image and the text canvas: one frame, decoded at start, handed
/// to whichever consumer holds the frame stream.
///
/// The compositor's slot keeps the latest frame it was given and has no
/// staleness rule, so a still needs to be delivered **once** per consumer
/// and the stream then simply stays open until ``stop()`` (ARCHITECTURE.md,
/// "Media inputs and the Library's Media tab"). One holder at a time, the
/// seam's rule: a new ``frames()`` call finishes the previous stream.
final class StillFrameHolder: Sendable {
    /// The held frame and the live consumer, behind one lock.
    private struct State {
        /// The decoded picture as first delivered, or nil before ``hold(_:)``
        /// and after ``stop()``. Held as a frame rather than a bare buffer
        /// so the state stays `Sendable` under the frame ownership rule.
        var frame: CapturedFrame?

        /// The one live frame stream's continuation, if a consumer holds it.
        var continuation: AsyncStream<CapturedFrame>.Continuation?
    }

    /// The state behind its lock.
    private let state = Mutex(State())

    /// The clock that stamps the frame's presentation time when it is
    /// delivered.
    private let clock: any EngineClock

    /// Creates a holder stamping deliveries from the given clock.
    init(clock: any EngineClock) {
        self.clock = clock
    }

    /// Holds the decoded picture, delivering it at once to a consumer
    /// already waiting on the stream.
    func hold(_ pixelBuffer: CVPixelBuffer) {
        let frame = CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: clock.now)
        state.withLock { state in
            state.frame = frame
            _ = state.continuation?.yield(frame)
        }
    }

    /// A stream delivering the held frame once, then staying open. Finishes
    /// any previous consumer's stream first.
    func frames() -> AsyncStream<CapturedFrame> {
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream()
        let now = clock.now
        state.withLock { state in
            state.continuation?.finish()
            state.continuation = continuation
            if let held = state.frame {
                continuation.yield(CapturedFrame(pixelBuffer: held.pixelBuffer, presentationTime: now))
            }
        }
        return stream
    }

    /// Finishes the live stream and releases the picture. Safe to call
    /// more than once.
    func stop() {
        state.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.frame = nil
        }
    }
}
