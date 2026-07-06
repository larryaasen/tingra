//
//  CompositorTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraComposition

/// A deterministic clock for tests, per CLOCK.md's substitution rule: the
/// tick stream yields exactly the scripted times, then finishes.
private struct SyntheticClock: EngineClock {
    /// The times the tick stream yields, in order.
    let tickTimes: [CMTime]

    /// Yields the scripted times regardless of the requested duration — the
    /// test decides the timeline.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { continuation in
            for time in tickTimes {
                continuation.yield(time)
            }
            continuation.finish()
        }
    }

    var now: CMTime { tickTimes.first ?? .zero }
}

/// Records what the tick handed the renderer, so a test can assert pacing,
/// stall, and shot-switch behavior with no Metal. `Sendable` and shared into
/// the mock renderer's factory (the renderer itself is task-confined).
private final class RenderRecorder: Sendable {
    /// One recorded render call: the shot, the input ids that had a frame,
    /// and the tick time stamped on the output.
    struct Call: Sendable {
        let shot: Shot
        let presentedInputs: Set<InputID>
        let time: CMTime
    }

    private let calls = Mutex<[Call]>([])

    /// Appends a recorded call.
    func record(_ call: Call) {
        calls.withLock { $0.append(call) }
    }

    /// The recorded calls so far.
    var recorded: [Call] {
        calls.withLock { $0 }
    }
}

/// A mock renderer that records each call and returns a 2x2 program frame,
/// standing in for Core Image so pacing is testable without a GPU.
private struct MockShotRenderer: ShotRenderer {
    let recorder: RenderRecorder

    func render(
        shot: Shot,
        frames: [InputID: CapturedFrame],
        format: ProgramFormat,
        time: CMTime
    ) -> CapturedFrame? {
        recorder.record(
            RenderRecorder.Call(shot: shot, presentedInputs: Set(frames.keys), time: time)
        )
        return CapturedFrame(pixelBuffer: makePixelBuffer(), presentationTime: time)
    }
}

/// A trivial input that yields a scripted number of frames then finishes,
/// standing in for a capture input under a synthetic clock.
private final class FakeInput: Input, Sendable {
    let id: InputID
    let name: String
    let kind: InputKind
    private let frameCount: Int

    init(id: String, kind: InputKind = .camera, frameCount: Int) {
        self.id = InputID(rawValue: id)
        self.name = id
        self.kind = kind
        self.frameCount = frameCount
    }

    func start() async throws {}
    func stop() async {}

    func frames() -> AsyncStream<CapturedFrame> {
        let count = frameCount
        return AsyncStream { continuation in
            for i in 0..<count {
                continuation.yield(
                    CapturedFrame(
                        pixelBuffer: makePixelBuffer(), presentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
                )
            }
            continuation.finish()
        }
    }
}

/// Creates a tiny 2x2 32BGRA buffer — enough to stand in for a program or
/// input frame in pacing tests.
private func makePixelBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
    // The tests never dereference the pixels; a nil here would only surface
    // as a force-unwrap, so fall back to a fresh 1x1 buffer instead.
    if let buffer { return buffer }
    var fallback: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, nil, &fallback)
    return fallback!
}

/// Drains up to `limit` program frames from the stream, returning their PTS.
private func collect(_ stream: AsyncStream<CapturedFrame>, limit: Int) async -> [CMTime] {
    var times: [CMTime] = []
    for await frame in stream {
        times.append(frame.presentationTime)
        if times.count == limit { break }
    }
    return times
}

@Suite("Compositor")
struct CompositorTests {
    /// A compositor over a synthetic clock and the mock renderer.
    private func makeCompositor(
        recorder: RenderRecorder,
        tickTimes: [CMTime],
        format: ProgramFormat = ProgramFormat(width: 2, height: 2, frameRate: 30)
    ) -> Compositor {
        Compositor(
            clock: SyntheticClock(tickTimes: tickTimes),
            format: format,
            eventBus: EventBus(),
            makeRenderer: { MockShotRenderer(recorder: recorder) }
        )
    }

    @Test("one program frame per tick, each stamped with the tick's time")
    func oneFramePerTickStampedWithTickTime() async {
        let ticks = [CMTime(value: 0, timescale: 30), CMTime(value: 1, timescale: 30), CMTime(value: 2, timescale: 30)]
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)

        let program = compositor.programFrames()
        compositor.start()

        let times = await collect(program, limit: 3)
        #expect(times == ticks)
        #expect(recorder.recorded.map(\.time) == ticks)
    }

    @Test("the program renders from the first tick even before any input delivers — a live background canvas")
    func rendersBackgroundBeforeInputsDeliver() async {
        let ticks = [CMTime(value: 0, timescale: 30), CMTime(value: 1, timescale: 30)]
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        // A shot referencing an input that never delivers a frame.
        compositor.setShot(Shot(layers: [Layer(input: InputID(rawValue: "camera"))]))

        let program = compositor.programFrames()
        compositor.start()

        let times = await collect(program, limit: 2)
        #expect(times.count == 2)
        // Every render happened, and none had a frame for the absent input.
        #expect(recorder.recorded.allSatisfy { $0.presentedInputs.isEmpty })
    }

    @Test("a switched shot takes effect on the next tick")
    func switchedShotTakesEffectNextTick() async {
        let ticks = (0..<4).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let first = Shot(layers: [Layer(input: InputID(rawValue: "a"))])
        let second = Shot(layers: [Layer(input: InputID(rawValue: "b"))])
        compositor.setShot(first)

        let program = compositor.programFrames()
        compositor.start()
        // Switch after the tick task has begun; later ticks see the new shot.
        compositor.setShot(second)
        _ = await collect(program, limit: 4)

        let shots = recorder.recorded.map(\.shot)
        #expect(shots.contains(second))
        #expect(shots.last == second)
    }

    @Test("an input's latest delivered frame is the one composited (latest wins)")
    func latestInputFrameIsComposited() async {
        // One tick, after an input that delivers three frames: the slot holds
        // the most recent, so the render sees the input present.
        let ticks = [CMTime(value: 10, timescale: 30)]
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let input = FakeInput(id: "camera", frameCount: 3)
        compositor.setShot(Shot(layers: [Layer(input: input.id)]))
        compositor.setInputs([input])
        // Let the fill task drain the input's frames into the slot first.
        try? await Task.sleep(nanoseconds: 20_000_000)

        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 1)

        #expect(recorder.recorded.count == 1)
        #expect(recorder.recorded.first?.presentedInputs == [input.id])
    }

    @Test("stop() finishes the program stream")
    func stopFinishesProgramStream() async {
        // A clock that would tick forever is not needed: stop() finishes the
        // consumer regardless of remaining ticks.
        let ticks = (0..<100).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)

        let program = compositor.programFrames()
        compositor.start()
        compositor.stop()

        var count = 0
        for await _ in program {
            count += 1
            if count > 200 { break }
        }
        #expect(count <= 100)
    }
}
