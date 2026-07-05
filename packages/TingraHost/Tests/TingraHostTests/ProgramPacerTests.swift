//
//  ProgramPacerTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Synchronization
import Testing
import TingraPlugInKit

@testable import TingraHost

/// Collects the paced frames a pacer emits.
private final class PacedFrames: Sendable {
    /// The collected frames, in emission order.
    private let frames = Mutex<[CapturedFrame]>([])

    /// Whether the paced stream has finished.
    private let finished = Mutex(false)

    /// Consumes the paced stream into the collection.
    func consume(_ stream: AsyncStream<CapturedFrame>) -> Task<Void, Never> {
        Task {
            for await frame in stream {
                frames.withLock { $0.append(frame) }
            }
            finished.withLock { $0 = true }
        }
    }

    /// The frames collected so far.
    var collected: [CapturedFrame] { frames.withLock { $0 } }

    /// Whether the paced stream has finished.
    var isFinished: Bool { finished.withLock { $0 } }
}

@Suite("ProgramPacer")
struct ProgramPacerTests {
    @Test("Ticks before the first frame arrives send nothing; the first frame is restamped with a tick time")
    func firstFrameIsRestamped() async throws {
        let clock = ManualClock()
        let pacer = ProgramPacer(clock: clock, frameRate: 30)
        let pixelBuffer = try #require(makeTestPixelBuffer())
        let (source, sourceContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)

        let output = PacedFrames()
        let consumer = output.consume(pacer.frames(from: source))
        defer { consumer.cancel() }

        // Ticks with an empty slot must emit nothing.
        clock.advance(to: CMTime(value: 1, timescale: 30))
        clock.advance(to: CMTime(value: 2, timescale: 30))
        #expect(output.collected.isEmpty)

        sourceContinuation.yield(
            CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: CMTime(value: 1, timescale: 60))
        )
        // Tick until the fill task has landed the frame in the slot; every
        // emitted frame then carries a tick time, not the capture time.
        let tick = Mutex(3)
        let produced = await eventually {
            let next = tick.withLock { value in
                value += 1
                return value
            }
            clock.advance(to: CMTime(value: CMTimeValue(next), timescale: 30))
            return !output.collected.isEmpty
        }
        #expect(produced)
        let first = try #require(output.collected.first)
        #expect(first.pixelBuffer === pixelBuffer)
        #expect(first.presentationTime.timescale == 30)
        sourceContinuation.finish()
    }

    @Test("A stalled source repeats the held frame with each new tick's time")
    func stallRepeatsLatestFrame() async throws {
        let clock = ManualClock()
        let pacer = ProgramPacer(clock: clock, frameRate: 30)
        let pixelBuffer = try #require(makeTestPixelBuffer())
        let (source, sourceContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)

        let output = PacedFrames()
        let consumer = output.consume(pacer.frames(from: source))
        defer { consumer.cancel() }

        sourceContinuation.yield(
            CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: .zero)
        )
        let tick = Mutex(1)
        _ = await eventually {
            let next = tick.withLock { value in
                value += 1
                return value
            }
            clock.advance(to: CMTime(value: CMTimeValue(next), timescale: 30))
            return !output.collected.isEmpty
        }
        // Let the ticks queued while polling drain, so the stall tick below
        // is unambiguously the newest emission.
        _ = await eventually {
            let before = output.collected.count
            try? await Task.sleep(for: .milliseconds(25))
            return output.collected.count == before
        }

        // No new source frame: the next tick re-sends the held frame with
        // the new tick's time (a stalled input must not stall the program).
        let stallTick = CMTime(value: 1000, timescale: 30)
        clock.advance(to: stallTick)
        let repeated = await eventually { output.collected.last?.presentationTime == stallTick }
        #expect(repeated)
        let last = try #require(output.collected.last)
        #expect(last.pixelBuffer === pixelBuffer)
        sourceContinuation.finish()
    }

    @Test("The latest frame wins when several arrive between ticks")
    func latestFrameWins() async throws {
        let clock = ManualClock()
        let pacer = ProgramPacer(clock: clock, frameRate: 30)
        let older = try #require(makeTestPixelBuffer())
        let newer = try #require(makeTestPixelBuffer())
        let (source, sourceContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)

        let output = PacedFrames()
        let consumer = output.consume(pacer.frames(from: source))
        defer { consumer.cancel() }

        sourceContinuation.yield(CapturedFrame(pixelBuffer: older, presentationTime: .zero))
        sourceContinuation.yield(
            CapturedFrame(pixelBuffer: newer, presentationTime: CMTime(value: 1, timescale: 60))
        )
        let tick = Mutex(1)
        let produced = await eventually {
            let next = tick.withLock { value in
                value += 1
                return value
            }
            clock.advance(to: CMTime(value: CMTimeValue(next), timescale: 30))
            // Both source frames precede the first landed tick read, so
            // whichever frame emerges must be the newer one.
            return !output.collected.isEmpty
        }
        #expect(produced)
        let first = try #require(output.collected.first)
        #expect(first.pixelBuffer === newer)
        sourceContinuation.finish()
    }

    @Test("The paced stream finishes after the source finishes")
    func finishesWithSource() async throws {
        let clock = ManualClock()
        let pacer = ProgramPacer(clock: clock, frameRate: 30)
        let (source, sourceContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)

        let output = PacedFrames()
        let consumer = output.consume(pacer.frames(from: source))
        defer { consumer.cancel() }

        sourceContinuation.finish()
        let tick = Mutex(1)
        let finished = await eventually {
            let next = tick.withLock { value in
                value += 1
                return value
            }
            clock.advance(to: CMTime(value: CMTimeValue(next), timescale: 30))
            return output.isFinished
        }
        #expect(finished)
        #expect(output.collected.isEmpty)
    }
}
