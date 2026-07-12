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
    /// the tick time stamped on the output, and — for a dissolve call — the
    /// outgoing shot and progress (`nil` for a plain render).
    struct Call: Sendable {
        let shot: Shot
        let presentedInputs: Set<InputID>
        let time: CMTime
        let dissolveOutgoing: Shot?
        let dissolveProgress: Double?
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
            RenderRecorder.Call(
                shot: shot, presentedInputs: Set(frames.keys), time: time, dissolveOutgoing: nil, dissolveProgress: nil
            )
        )
        return CapturedFrame(pixelBuffer: makePixelBuffer(), presentationTime: time)
    }

    func renderDissolve(
        from outgoing: Shot,
        to incoming: Shot,
        progress: Double,
        frames: [InputID: CapturedFrame],
        format: ProgramFormat,
        time: CMTime
    ) -> CapturedFrame? {
        recorder.record(
            RenderRecorder.Call(
                shot: incoming,
                presentedInputs: Set(frames.keys),
                time: time,
                dissolveOutgoing: outgoing,
                dissolveProgress: progress
            )
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

    @Test("loading a preset cuts to its first shot")
    func loadPresetCutsToFirstShot() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))

        #expect(compositor.activeShotID == display.id)
        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 2)
        #expect(recorder.recorded.allSatisfy { $0.shot == display })
    }

    @Test("taking a shot by id cuts to it on the next tick")
    func takeSwitchesActiveShot() async {
        let ticks = (0..<4).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))

        let program = compositor.programFrames()
        compositor.start()
        compositor.take(shotID: camera.id)
        _ = await collect(program, limit: 4)

        #expect(compositor.activeShotID == camera.id)
        let shots = recorder.recorded.map(\.shot)
        #expect(shots.contains(camera))
        #expect(shots.last == camera)
        // The default transition is still a cut: no tick ever blends.
        #expect(recorder.recorded.allSatisfy { $0.dissolveProgress == nil })
    }

    @Test("taking a shot with a dissolve crossfades over its duration, then settles on the incoming shot")
    func takeWithDissolveCrossfadesOverDuration() async {
        // 30 fps, a 0.1s dissolve — exactly 3 ticks — followed by 2 plain
        // ticks once the dissolve has completed.
        let ticks = (0..<5).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))

        let program = compositor.programFrames()
        compositor.start()
        compositor.take(shotID: camera.id, transition: .dissolve(duration: 0.1))
        _ = await collect(program, limit: 5)

        let calls = recorder.recorded
        #expect(calls.count == 5)

        // The first three ticks blend, ramping from just past outgoing
        // toward fully incoming.
        let dissolveProgresses = calls.prefix(3).map(\.dissolveProgress)
        #expect(dissolveProgresses.allSatisfy { $0 != nil })
        #expect(abs((dissolveProgresses[0] ?? 0) - 1.0 / 3.0) < 0.0001)
        #expect(abs((dissolveProgresses[1] ?? 0) - 2.0 / 3.0) < 0.0001)
        #expect(abs((dissolveProgresses[2] ?? 0) - 1.0) < 0.0001)
        #expect(calls.prefix(3).allSatisfy { $0.dissolveOutgoing == display })
        #expect(calls.prefix(3).allSatisfy { $0.shot == camera })

        // Once the dissolve completes, later ticks render the incoming shot
        // plainly — no more blending.
        #expect(calls.suffix(2).allSatisfy { $0.dissolveProgress == nil })
        #expect(calls.suffix(2).allSatisfy { $0.shot == camera })

        // Taking effect immediately (matching the cut's contract): the
        // active shot id updates without waiting for the dissolve to finish.
        #expect(compositor.activeShotID == camera.id)
    }

    @Test("a zero-duration dissolve still transitions, completing on its first tick")
    func zeroDurationDissolveCompletesImmediately() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))

        let program = compositor.programFrames()
        compositor.start()
        compositor.take(shotID: camera.id, transition: .dissolve(duration: 0))
        _ = await collect(program, limit: 2)

        let calls = recorder.recorded
        #expect(calls.count == 2)
        // The first (and only) blended tick lands at full progress.
        #expect(abs((calls[0].dissolveProgress ?? 0) - 1.0) < 0.0001)
        // Every subsequent tick is a plain render — no dangling transition.
        #expect(calls[1].dissolveProgress == nil)
    }

    @Test("taking an unknown shot id leaves the program on the current shot")
    func takeUnknownShotIsIgnored() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        compositor.loadPreset(Preset(name: "Live", shots: [display]))

        compositor.take(shotID: ShotID(rawValue: "does-not-exist"))
        #expect(compositor.activeShotID == display.id)

        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 2)
        #expect(recorder.recorded.allSatisfy { $0.shot == display })
    }

    @Test("updating the active shot renders the edited layer tree on the next tick — no separate apply step")
    func updateActiveShotRendersEditedTree() async {
        let ticks = (0..<3).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        compositor.loadPreset(Preset(name: "Live", shots: [display]))

        let edited = Shot(
            id: display.id,
            name: display.name,
            layers: [Layer(input: InputID(rawValue: "camera"), opacity: 0.5)]
        )
        compositor.updateShot(edited)

        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 3)

        // The edit is live: every tick after the update renders the edited
        // layer tree, and editing never changes which shot is on program.
        #expect(recorder.recorded.allSatisfy { $0.shot == edited })
        #expect(compositor.activeShotID == display.id)
    }

    @Test("an edited shot keeps its edits across shot switches within the session")
    func updatedShotSurvivesShotSwitches() async {
        let ticks = (0..<4).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))

        let edited = Shot(id: display.id, name: display.name, layers: [Layer(input: InputID(rawValue: "extra"))])
        compositor.updateShot(edited)
        // Switch away and back: the loaded preset holds the edited shot.
        compositor.take(shotID: camera.id)
        compositor.take(shotID: display.id)

        #expect(compositor.shots.first { $0.id == display.id } == edited)
        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 4)
        #expect(recorder.recorded.last?.shot == edited)
    }

    @Test("updating a shot that is not on program changes the pool but not the live render")
    func updateInactiveShotLeavesProgramUnchanged() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))

        let edited = Shot(id: camera.id, name: camera.name, layers: [Layer(input: InputID(rawValue: "extra"))])
        compositor.updateShot(edited)

        #expect(compositor.shots.first { $0.id == camera.id } == edited)
        #expect(compositor.activeShotID == display.id)
        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 2)
        // The program keeps rendering the untouched active shot.
        #expect(recorder.recorded.allSatisfy { $0.shot == display })
    }

    @Test("updating an unknown shot id leaves the loaded preset unchanged")
    func updateUnknownShotIsIgnored() async {
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: [])
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        compositor.loadPreset(Preset(name: "Live", shots: [display]))

        compositor.updateShot(Shot(id: ShotID(rawValue: "does-not-exist"), name: "Ghost"))

        #expect(compositor.shots == [display])
        #expect(compositor.activeShotID == display.id)
    }

    @Test("updating the incoming shot mid-dissolve makes the dissolve continue toward the edited tree")
    func updateIncomingShotMidDissolve() async {
        // 30 fps, a 0.1s dissolve — exactly 3 ticks. The edit lands before
        // any tick runs, so every blended tick already targets the edit.
        let ticks = (0..<4).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))
        compositor.take(shotID: camera.id, transition: .dissolve(duration: 0.1))

        let edited = Shot(id: camera.id, name: camera.name, layers: [Layer(input: InputID(rawValue: "extra"))])
        compositor.updateShot(edited)

        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 4)

        let calls = recorder.recorded
        // The blended ticks dissolve from the outgoing shot toward the
        // edited incoming tree, then settle on it.
        #expect(calls.prefix(3).allSatisfy { $0.dissolveOutgoing == display && $0.shot == edited })
        #expect(calls.last?.dissolveProgress == nil)
        #expect(calls.last?.shot == edited)
    }

    @Test("adding a shot appends it to the pool without changing the program — adding is not taking")
    func addShotAppendsWithoutTaking() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        compositor.loadPreset(Preset(name: "Live", shots: [display]))

        let added = Shot(id: ShotID(rawValue: "interview"), name: "Interview")
        compositor.addShot(added)

        #expect(compositor.shots == [display, added])
        #expect(compositor.activeShotID == display.id)
        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 2)
        // The program keeps rendering the shot that was already on air.
        #expect(recorder.recorded.allSatisfy { $0.shot == display })
    }

    @Test("adding a shot at an index inserts it at that switcher position")
    func addShotInsertsAtIndex() {
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: [])
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))

        // The duplicate-insertion pattern: the copy lands right after its
        // source. An out-of-range index clamps rather than traps.
        let copy = Shot(id: ShotID(rawValue: "display-copy"), name: "Display copy")
        compositor.addShot(copy, at: 1)
        let clamped = Shot(id: ShotID(rawValue: "clamped"), name: "Clamped")
        compositor.addShot(clamped, at: 99)

        #expect(compositor.shots == [display, copy, camera, clamped])
    }

    @Test("adding a shot whose id is already loaded leaves the pool unchanged")
    func addShotWithDuplicateIDIsIgnored() {
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: [])
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        compositor.loadPreset(Preset(name: "Live", shots: [display]))

        compositor.addShot(Shot(id: display.id, name: "Impostor"))

        #expect(compositor.shots == [display])
    }

    @Test("adding a shot to an empty pool makes it available but does not take it")
    func addShotToEmptyPoolDoesNotTake() {
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: [])
        compositor.loadPreset(Preset(name: "Live", shots: []))

        let added = Shot(id: ShotID(rawValue: "opening"), name: "Opening")
        compositor.addShot(added)

        #expect(compositor.shots == [added])
        #expect(compositor.activeShotID == nil)

        // Taking it is the caller's explicit move.
        compositor.take(shotID: added.id)
        #expect(compositor.activeShotID == added.id)
    }

    @Test("removing a shot that is not on program shrinks the pool and leaves the live render unchanged")
    func removeInactiveShotLeavesProgramUnchanged() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))

        compositor.removeShot(shotID: camera.id)

        #expect(compositor.shots == [display])
        #expect(compositor.activeShotID == display.id)
        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 2)
        #expect(recorder.recorded.allSatisfy { $0.shot == display })
    }

    @Test("removing the shot on program cuts to the shot now occupying its switcher position")
    func removeActiveShotCutsToFollower() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        let wide = Shot(id: ShotID(rawValue: "wide"), name: "Wide")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera, wide]))
        compositor.take(shotID: camera.id)

        compositor.removeShot(shotID: camera.id)

        // The follower (wide) now occupies the removed shot's position.
        #expect(compositor.shots == [display, wide])
        #expect(compositor.activeShotID == wide.id)
        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 2)
        #expect(recorder.recorded.allSatisfy { $0.shot == wide })
    }

    @Test("removing the last-position shot on program cuts to the previous shot")
    func removeActiveLastShotCutsToPrevious() {
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: [])
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))
        compositor.take(shotID: camera.id)

        compositor.removeShot(shotID: camera.id)

        #expect(compositor.shots == [display])
        #expect(compositor.activeShotID == display.id)
    }

    @Test("removing the only shot leaves the background-only canvas on program — never a dead program")
    func removeOnlyShotLeavesBackgroundCanvas() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        compositor.loadPreset(Preset(name: "Live", shots: [display]))

        compositor.removeShot(shotID: display.id)

        #expect(compositor.shots.isEmpty)
        #expect(compositor.activeShotID == nil)
        // The tick keeps rendering: an empty shot over the default background
        // is still a live canvas.
        let program = compositor.programFrames()
        compositor.start()
        let times = await collect(program, limit: 2)
        #expect(times.count == 2)
        // `Shot()` mints a fresh id, so compare the canvas by content: no
        // layers over the default background.
        #expect(recorder.recorded.allSatisfy { $0.shot.layers.isEmpty && $0.shot.background == .black })
    }

    @Test("removing an unknown shot id leaves the loaded preset unchanged")
    func removeUnknownShotIsIgnored() {
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: [])
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        compositor.loadPreset(Preset(name: "Live", shots: [display]))

        compositor.removeShot(shotID: ShotID(rawValue: "does-not-exist"))

        #expect(compositor.shots == [display])
        #expect(compositor.activeShotID == display.id)
    }

    @Test("removing the incoming shot mid-dissolve clears the dissolve and cuts to the adjacent shot")
    func removeIncomingShotMidDissolveCuts() async {
        let ticks = (0..<2).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))
        // A dissolve long enough that it would still be blending on every
        // scripted tick if the removal did not clear it.
        compositor.take(shotID: camera.id, transition: .dissolve(duration: 10))

        compositor.removeShot(shotID: camera.id)

        #expect(compositor.activeShotID == display.id)
        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 2)
        // A hard cut: no tick blends, every tick renders the adjacent shot.
        #expect(recorder.recorded.allSatisfy { $0.dissolveProgress == nil })
        #expect(recorder.recorded.allSatisfy { $0.shot == display })
    }

    @Test("removing the outgoing shot mid-dissolve lets the dissolve finish from its snapshot")
    func removeOutgoingShotMidDissolveContinues() async {
        // 30 fps, a 0.1s dissolve — exactly 3 ticks, plus one settled tick.
        let ticks = (0..<4).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let recorder = RenderRecorder()
        let compositor = makeCompositor(recorder: recorder, tickTimes: ticks)
        let display = Shot(id: ShotID(rawValue: "display"), name: "Display")
        let camera = Shot(id: ShotID(rawValue: "camera"), name: "Camera")
        compositor.loadPreset(Preset(name: "Live", shots: [display, camera]))
        compositor.take(shotID: camera.id, transition: .dissolve(duration: 0.1))

        // The outgoing shot leaves the pool, but it is on its way off
        // program — the dissolve keeps rendering from its snapshot.
        compositor.removeShot(shotID: display.id)

        #expect(compositor.shots == [camera])
        #expect(compositor.activeShotID == camera.id)
        let program = compositor.programFrames()
        compositor.start()
        _ = await collect(program, limit: 4)
        let calls = recorder.recorded
        #expect(calls.prefix(3).allSatisfy { $0.dissolveOutgoing == display && $0.shot == camera })
        #expect(calls.last?.dissolveProgress == nil)
        #expect(calls.last?.shot == camera)
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
