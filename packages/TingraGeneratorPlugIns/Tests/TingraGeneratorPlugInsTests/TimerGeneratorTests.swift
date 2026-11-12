//
//  TimerGeneratorTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("TimerGenerator")
struct TimerGeneratorTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 320

    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let height = 180

    /// A generator at the tests' geometry.
    private static func makeGenerator(clock: any EngineClock) -> TimerGenerator {
        TimerGenerator(clock: clock, width: width, height: height, frameRate: 30)
    }

    /// The payload that asks for a state.
    private static func state(_ state: RunState) -> [String: JSONValue] {
        ["state": .double(Double(state.rawValue))]
    }

    @Test("the generator carries its stable identifier, name, kind, and media")
    func identity() {
        let generator = TimerGenerator(clock: SyntheticClock())

        #expect(generator.id == TimerGenerator.inputID)
        #expect(generator.id == InputID(rawValue: "timer"))
        #expect(generator.name == "Timer")
        #expect(generator.kind == .generator)
        #expect(generator.media == .video)
    }

    @Test("it declares the state choice, then the shared appearance")
    func declaresParameters() {
        let parameters = TimerGenerator(clock: SyntheticClock()).parameters

        #expect(parameters.map(\.key) == ["state", "position", "sizePercent", "textColor", "background"])
        #expect(parameters.first?.kind == .choice)
    }

    @Test("by default it is running, in the top right corner, a tenth of the frame tall")
    func defaults() {
        let settings = TimerGenerator(clock: SyntheticClock()).currentSettings

        #expect(settings.stopwatch.state == .running)
        #expect(settings.style.position == .topRight)
        #expect(settings.style.sizeFraction == 0.1)
    }

    @Test("it counts whole seconds up from the master clock time it was created at")
    func countsUpFromCreation() {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(1000)))

        #expect(generator.text(at: seconds(1000)) == "00:00")
        #expect(generator.text(at: seconds(1000.9)) == "00:00")
        #expect(generator.text(at: seconds(1001)) == "00:01")
        #expect(generator.text(at: seconds(1065)) == "01:05")
        #expect(generator.text(at: seconds(1000 + 3725)) == "1:02:05")
    }

    @Test("a tick a hair short of a second in floating point still reads as that second")
    func secondBoundaryIsNotLostToRounding() {
        let generator = Self.makeGenerator(clock: SettableClock(now: .zero))
        let almostOne = CMTime(value: 999_999_999, timescale: 1_000_000_000)

        #expect(generator.text(at: almostOne) == "00:01")
    }

    @Test("Paused holds the count and Running resumes it")
    func pauseAndResume() async {
        let clock = SettableClock(now: seconds(0))
        let generator = Self.makeGenerator(clock: clock)

        clock.set(seconds: 30)
        await generator.setParameters(Self.state(.paused))
        #expect(generator.text(at: seconds(30)) == "00:30")
        #expect(generator.text(at: seconds(500)) == "00:30")

        clock.set(seconds: 600)
        await generator.setParameters(Self.state(.running))
        #expect(generator.text(at: seconds(600)) == "00:30")
        #expect(generator.text(at: seconds(615)) == "00:45")
    }

    @Test("Reset returns to zero and holds; Running then starts from zero")
    func resetAndStart() async {
        let clock = SettableClock(now: seconds(0))
        let generator = Self.makeGenerator(clock: clock)

        clock.set(seconds: 75)
        await generator.setParameters(Self.state(.reset))
        #expect(generator.text(at: seconds(75)) == "00:00")
        #expect(generator.text(at: seconds(900)) == "00:00")

        clock.set(seconds: 1000)
        await generator.setParameters(Self.state(.running))
        #expect(generator.text(at: seconds(1012)) == "00:12")
    }

    @Test("applying the same payload again, or changing only the appearance, never restarts the count")
    func reapplyingDoesNotRestart() async {
        let clock = SettableClock(now: seconds(0))
        let generator = Self.makeGenerator(clock: clock)

        clock.set(seconds: 40)
        await generator.setParameters(Self.state(.running))
        await generator.setParameters(["state": .double(1), "position": .double(0), "sizePercent": .double(30)])

        #expect(generator.text(at: seconds(50)) == "00:50")
        #expect(generator.currentSettings.style.position == .center)
        #expect(generator.currentSettings.style.sizeFraction == 0.3)
    }

    @Test("an empty payload restores the defaults: Running, so a held timer starts from where it was")
    func emptyPayloadRestoresDefaults() async {
        let clock = SettableClock(now: seconds(0))
        let generator = Self.makeGenerator(clock: clock)
        await generator.setParameters(Self.state(.reset))

        clock.set(seconds: 20)
        await generator.setParameters([:])

        #expect(generator.currentSettings.stopwatch.state == .running)
        #expect(generator.text(at: seconds(25)) == "00:05")
    }

    @Test("one frame per clock tick, stamped with the tick's master clock time")
    func oneFramePerTickWithTickPTS() async {
        let ticks = [seconds(0), seconds(0.5), seconds(1)]
        let generator = Self.makeGenerator(clock: SyntheticClock(tickTimes: ticks))

        var times: [CMTime] = []
        for await frame in generator.frames() {
            times.append(frame.presentationTime)
        }

        #expect(times == ticks)
    }

    @Test("frames are in the working format and transparent outside the timer, which sits top right")
    func framesAreTransparentWithTheTimerInItsCorner() async throws {
        let generator = Self.makeGenerator(clock: SyntheticClock(tickTimes: [.zero]))

        var frames: [CapturedFrame] = []
        for await frame in generator.frames() {
            frames.append(frame)
        }

        let buffer = try #require(frames.first?.pixelBuffer)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) != nil)
        let pixels = try bgraPixels(of: buffer)
        #expect(pixels.first?.alpha == 0)
        let bounds = try #require(try inkBounds(of: buffer))
        #expect(bounds.minX > Self.width / 2)
        #expect(bounds.maxY < Self.height / 2)
    }

    @Test("the picture changes when the second does, and not before")
    func bufferChangesWithTheSecond() async throws {
        let ticks = [seconds(0), seconds(0.5), seconds(1)]
        let generator = Self.makeGenerator(clock: SyntheticClock(tickTimes: ticks))

        var frames: [CapturedFrame] = []
        for await frame in generator.frames() {
            frames.append(frame)
        }

        try #require(frames.count == 3)
        #expect(frames[0].pixelBuffer === frames[1].pixelBuffer)
        #expect(frames[1].pixelBuffer !== frames[2].pixelBuffer)
    }

    @Test("stop() finishes a live frame stream")
    func stopFinishesStream() async {
        let generator = Self.makeGenerator(clock: SyntheticClock(staysOpen: true))
        let frames = generator.frames()
        let consumer = Task {
            var count = 0
            for await _ in frames {
                count += 1
            }
            return count
        }

        await generator.stop()

        #expect(await consumer.value == 0)
    }
}
