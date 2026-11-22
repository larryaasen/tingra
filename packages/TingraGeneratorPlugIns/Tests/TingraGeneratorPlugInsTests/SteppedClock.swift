//
//  SteppedClock.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Synchronization
import TingraPlugInKit

/// A deterministic clock the test advances one tick at a time, so it can take
/// each output before the next is made. An input's streams hold only the
/// newest frame (ARCHITECTURE.md, "Bounded frame streams"), so a test that
/// counts every frame must not let the input run ahead of it, as
/// ``SyntheticClock`` does by yielding every tick at once.
final class SteppedClock: EngineClock {
    /// The tick stream's continuation once the input subscribes, and the
    /// ticks sent before it did.
    private struct State {
        /// The subscribed tick stream, if any.
        var continuation: AsyncStream<CMTime>.Continuation?

        /// Ticks advanced to before the input subscribed, in order.
        var pending: [CMTime] = []

        /// Whether ``finish()`` was called.
        var isFinished = false
    }

    /// The clock's state behind its lock.
    private let state = Mutex(State())

    /// The clock's reading, fixed like ``SyntheticClock``'s: inputs that
    /// anchor wall time to `now` measure each tick against it.
    let now: CMTime

    /// Creates a clock whose reading is `now`.
    ///
    /// - Parameter now: The fixed reading; zero by default, the first tick
    ///   the tests send.
    init(now: CMTime = .zero) {
        self.now = now
    }

    /// Yields the ticks the test advances to, whatever the requested
    /// duration, replaying any sent before this call.
    ///
    /// - Parameter duration: Ignored; the test decides the timeline.
    /// - Returns: The tick stream.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        let (stream, continuation) = AsyncStream.makeStream(of: CMTime.self)
        state.withLock { state in
            state.continuation = continuation
            for time in state.pending {
                continuation.yield(time)
            }
            state.pending.removeAll()
            if state.isFinished { continuation.finish() }
        }
        return stream
    }

    /// Sends one tick, held until the input subscribes if it has not yet.
    ///
    /// - Parameter time: The tick's master clock time.
    func advance(to time: CMTime) {
        state.withLock { state in
            if let continuation = state.continuation {
                continuation.yield(time)
            } else {
                state.pending.append(time)
            }
        }
    }

    /// Ends the tick stream, so the input's streams finish.
    func finish() {
        state.withLock { state in
            state.isFinished = true
            state.continuation?.finish()
        }
    }
}

/// Each tick's output from `stream`, taken before the next tick is sent, then
/// the clock finished: every output of a stream bounded to the newest one.
/// Attach the stream before calling, as `frames()` and `audio()` do.
///
/// - Parameters:
///   - stream: The input's output stream.
///   - clock: The clock pacing the input.
///   - ticks: The ticks to send, in order.
/// - Returns: One output per tick, or fewer if the stream finished early.
func steppedOutputs<Output>(of stream: AsyncStream<Output>, clock: SteppedClock, ticks: [CMTime]) async -> [Output] {
    var iterator = stream.makeAsyncIterator()
    var outputs: [Output] = []
    for time in ticks {
        clock.advance(to: time)
        guard let output = await iterator.next() else { break }
        outputs.append(output)
    }
    clock.finish()
    return outputs
}
