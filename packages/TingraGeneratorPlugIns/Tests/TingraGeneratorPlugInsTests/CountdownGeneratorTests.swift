//
//  CountdownGeneratorTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

/// A wall clock a test moves by hand, standing in for `Date.now`.
private final class SettableWallClock: Sendable {
    /// The current wall-clock moment, as last set.
    private let storage: Mutex<Date>

    /// Creates a wall clock reading `date`.
    init(_ date: Date) {
        storage = Mutex(date)
    }

    /// The current wall-clock moment.
    var now: Date { storage.withLock { $0 } }

    /// Moves the wall clock to a moment.
    func set(_ date: Date) {
        storage.withLock { $0 = date }
    }
}

@Suite("CountdownGenerator")
struct CountdownGeneratorTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 320

    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let height = 180

    /// UTC, so the fixed wall clock reads the same on every Mac.
    private static let utc = TimeZone(secondsFromGMT: 0) ?? .gmt

    /// 2026-11-11 00:00:00 UTC.
    private static let midnight = Date(timeIntervalSince1970: 1_794_355_200)

    /// 2026-11-11 18:30:00 UTC, the fixed wall clock.
    private static let evening = midnight.addingTimeInterval(18 * 3600 + 30 * 60)

    /// A generator on a clock and a fixed (or settable) wall clock.
    private static func makeGenerator(
        clock: any EngineClock,
        wallClock: @escaping @Sendable () -> Date = { evening }
    ) -> CountdownGenerator {
        CountdownGenerator(
            clock: clock,
            width: width,
            height: height,
            frameRate: 30,
            wallClock: wallClock,
            timeZone: utc
        )
    }

    /// A duration payload, in a state.
    private static func duration(
        hours: Double = 0,
        minutes: Double = 0,
        seconds: Double = 0,
        state: RunState = .running,
        repeats: Bool = false
    ) -> [String: JSONValue] {
        [
            "target": .double(0),
            "hours": .double(hours),
            "minutes": .double(minutes),
            "seconds": .double(seconds),
            "state": .double(Double(state.rawValue)),
            "repeats": .bool(repeats),
        ]
    }

    /// A time-of-day payload.
    private static func timeOfDay(hour: Double, minute: Double) -> [String: JSONValue] {
        ["target": .double(1), "targetHour": .double(hour), "targetMinute": .double(minute)]
    }

    @Test("the generator carries its stable identifier, name, kind, and media")
    func identity() {
        let generator = CountdownGenerator(clock: SyntheticClock())

        #expect(generator.id == CountdownGenerator.inputID)
        #expect(generator.id == InputID(rawValue: "countdown"))
        #expect(generator.name == "Countdown")
        #expect(generator.kind == .generator)
        #expect(generator.media == .video)
    }

    @Test("it declares the target, the duration and its controls, the time of day, then the appearance")
    func declaresParameters() {
        let parameters = CountdownGenerator(clock: SyntheticClock()).parameters

        #expect(
            parameters.map(\.key) == [
                "target", "hours", "minutes", "seconds", "state", "repeats", "targetHour", "targetMinute",
                "position", "sizePercent", "textColor", "background",
            ])
        #expect(Set(parameters.map(\.key)).count == parameters.count)
        #expect(parameters.first?.choices.map(\.name) == ["Duration", "Time of Day"])
        #expect(parameters[1...5].allSatisfy { $0.section == "Duration" })
        #expect(parameters[6...7].allSatisfy { $0.section == "Time of Day" })
        #expect(parameters[1...3].allSatisfy { $0.step == 1 })
    }

    @Test("by default it counts five minutes, running, centered, a quarter of the frame tall")
    func defaults() {
        let settings = CountdownGenerator(clock: SyntheticClock()).currentSettings

        #expect(settings.target == .duration)
        #expect(settings.durationSeconds == 300)
        #expect(!settings.repeats)
        #expect(settings.stopwatch.state == .running)
        #expect(settings.targetDate == nil)
        #expect(settings.style.position == .center)
        #expect(settings.style.sizeFraction == 0.25)
    }

    @Test("a duration counts down on the master clock from the time it was created at")
    func durationCountsDown() {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(1000)))

        #expect(generator.text(at: seconds(1000)) == "05:00")
        #expect(generator.text(at: seconds(1001)) == "04:59")
        #expect(generator.text(at: seconds(1240)) == "01:00")
        #expect(generator.text(at: seconds(1299)) == "00:01")
    }

    @Test("the remaining time is rounded up, so the last second shows 00:01 until zero itself")
    func remainingRoundsUp() {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))

        #expect(generator.text(at: seconds(0.5)) == "05:00")
        #expect(generator.text(at: seconds(299.5)) == "00:01")
        #expect(generator.text(at: seconds(300)) == "00:00")
    }

    @Test("it holds at zero once it gets there")
    func holdsAtZero() {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))

        #expect(generator.text(at: seconds(301)) == "00:00")
        #expect(generator.text(at: seconds(90_000)) == "00:00")
    }

    @Test("hours, minutes, and seconds add up to the duration, shown with hours from an hour up")
    func durationFromItsParts() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))

        await generator.setParameters(Self.duration(hours: 1, minutes: 30, seconds: 15))

        #expect(generator.currentSettings.durationSeconds == 5415)
        #expect(generator.text(at: seconds(0)) == "1:30:15")
        #expect(generator.text(at: seconds(1815)) == "1:00:00")
        #expect(generator.text(at: seconds(1816)) == "59:59")
    }

    @Test("duration values are clamped to their ranges and snapped to whole numbers")
    func durationValuesAreTamed() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))

        await generator.setParameters(Self.duration(hours: 99, minutes: -4, seconds: 29.6))

        #expect(generator.currentSettings.durationSeconds == 23 * 3600 + 30)
    }

    @Test("a zero duration shows 00:00, repeating or not")
    func zeroDurationShowsZero() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))

        await generator.setParameters(Self.duration())
        #expect(generator.text(at: seconds(10)) == "00:00")

        await generator.setParameters(Self.duration(repeats: true))
        #expect(generator.text(at: seconds(10)) == "00:00")
    }

    @Test("Reset shows the full duration and holds; Running starts it; Paused holds it")
    func startPauseReset() async {
        let clock = SettableClock(now: seconds(0))
        let generator = Self.makeGenerator(clock: clock)

        await generator.setParameters(Self.duration(minutes: 2, state: .reset))
        #expect(generator.text(at: seconds(500)) == "02:00")

        clock.set(seconds: 1000)
        await generator.setParameters(Self.duration(minutes: 2, state: .running))
        #expect(generator.text(at: seconds(1000)) == "02:00")
        #expect(generator.text(at: seconds(1045)) == "01:15")

        clock.set(seconds: 1045)
        await generator.setParameters(Self.duration(minutes: 2, state: .paused))
        #expect(generator.text(at: seconds(2000)) == "01:15")

        clock.set(seconds: 3000)
        await generator.setParameters(Self.duration(minutes: 2, state: .running))
        #expect(generator.text(at: seconds(3015)) == "01:00")

        await generator.setParameters(Self.duration(minutes: 2, state: .reset))
        #expect(generator.text(at: seconds(3500)) == "02:00")
    }

    @Test("applying the same payload again never restarts the count")
    func reapplyingDoesNotRestart() async {
        let clock = SettableClock(now: seconds(0))
        let generator = Self.makeGenerator(clock: clock)
        await generator.setParameters(Self.duration(minutes: 2))

        clock.set(seconds: 60)
        await generator.setParameters(Self.duration(minutes: 2))

        #expect(generator.text(at: seconds(60)) == "01:00")
    }

    @Test("changing the duration while it runs changes what is left, not when it started")
    func changingDurationKeepsElapsed() async {
        let clock = SettableClock(now: seconds(0))
        let generator = Self.makeGenerator(clock: clock)

        clock.set(seconds: 60)
        await generator.setParameters(Self.duration(minutes: 10))

        #expect(generator.text(at: seconds(60)) == "09:00")
    }

    @Test("with Repeat on it starts over each time it reaches zero: an interval timer")
    func repeatStartsOver() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))

        await generator.setParameters(Self.duration(seconds: 30, repeats: true))

        #expect(generator.text(at: seconds(0)) == "00:30")
        #expect(generator.text(at: seconds(29)) == "00:01")
        #expect(generator.text(at: seconds(30)) == "00:30")
        #expect(generator.text(at: seconds(45)) == "00:15")
        #expect(generator.text(at: seconds(30 * 100 + 10)) == "00:20")
    }

    @Test("a time of day counts down to the next time the wall clock reads it")
    func timeOfDayCountsToNextOccurrence() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(5000)))

        await generator.setParameters(Self.timeOfDay(hour: 19, minute: 0))

        #expect(generator.currentSettings.target == .timeOfDay)
        #expect(generator.currentSettings.targetDate == Self.midnight.addingTimeInterval(19 * 3600))
        #expect(generator.text(at: seconds(5000)) == "30:00")
        #expect(generator.text(at: seconds(5060)) == "29:00")
    }

    @Test("a time of day already past today counts to tomorrow's")
    func pastTimeOfDayIsTomorrow() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))

        await generator.setParameters(Self.timeOfDay(hour: 18, minute: 0))

        #expect(generator.currentSettings.targetDate == Self.midnight.addingTimeInterval((24 + 18) * 3600))
        #expect(generator.text(at: seconds(0)) == "23:30:00")
    }

    @Test("a time of day follows the wall clock, and holds at zero after the moment passes")
    func timeOfDayHoldsAtZero() async {
        let wall = SettableWallClock(Self.evening)
        let clock = SettableClock(now: seconds(0))
        let generator = Self.makeGenerator(clock: clock, wallClock: { wall.now })
        await generator.setParameters(Self.timeOfDay(hour: 19, minute: 0))

        // Twenty minutes on, by both clocks.
        wall.set(Self.evening.addingTimeInterval(1200))
        clock.set(seconds: 1200)
        #expect(generator.text(at: seconds(1200)) == "10:00")

        // Past the hour: zero, not a day's wait for the next 19:00 — even
        // when the host sends the same payload again.
        wall.set(Self.evening.addingTimeInterval(2400))
        clock.set(seconds: 2400)
        #expect(generator.text(at: seconds(2400)) == "00:00")
        await generator.setParameters(Self.timeOfDay(hour: 19, minute: 0))
        #expect(generator.text(at: seconds(2400)) == "00:00")
    }

    @Test("a new hour or minute moves the target; switching to a duration drops it")
    func changingTheTimeOfDayResolvesAgain() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))
        await generator.setParameters(Self.timeOfDay(hour: 19, minute: 0))

        await generator.setParameters(Self.timeOfDay(hour: 19, minute: 15))
        #expect(generator.currentSettings.targetDate == Self.midnight.addingTimeInterval(19 * 3600 + 15 * 60))
        #expect(generator.text(at: seconds(0)) == "45:00")

        await generator.setParameters(Self.duration(minutes: 1))
        #expect(generator.currentSettings.targetDate == nil)
        #expect(generator.currentSettings.target == .duration)

        await generator.setParameters(Self.timeOfDay(hour: 19, minute: 15))
        #expect(generator.currentSettings.targetDate == Self.midnight.addingTimeInterval(19 * 3600 + 15 * 60))
    }

    @Test("the next occurrence is read in the given zone, across a daylight saving change")
    func nextOccurrenceReadsTheZone() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        // 2026-10-31 20:00 in New York (EDT, UTC−4); clocks go back that night.
        let saturdayEvening = Date(timeIntervalSince1970: 1_793_491_200)

        let next = try #require(
            CountdownGenerator.nextOccurrence(ofHour: 9, minute: 30, after: saturdayEvening, in: newYork))

        // 09:30 EST on November 1 is 14:30 UTC: 14.5 hours on, not 13.5.
        #expect(next.timeIntervalSince(saturdayEvening) == 14.5 * 3600)
    }

    @Test("an empty payload restores the defaults")
    func emptyPayloadRestoresDefaults() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(0)))
        let defaults = generator.currentSettings

        await generator.setParameters(Self.timeOfDay(hour: 19, minute: 0))
        #expect(generator.currentSettings != defaults)

        await generator.setParameters([:])
        #expect(generator.currentSettings == defaults)
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

    @Test("frames are in the working format and transparent outside the countdown, which sits in the middle")
    func framesAreTransparentWithTheCountdownCentered() async throws {
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
        #expect(pixels.last?.alpha == 0)
        let bounds = try #require(try inkBounds(of: buffer))
        #expect(bounds.minX < Self.width / 2 && bounds.maxX > Self.width / 2)
        #expect(bounds.minY < Self.height / 2 && bounds.maxY > Self.height / 2)
    }

    @Test("the picture changes when the second does, and not before")
    func bufferChangesWithTheSecond() async throws {
        let ticks = [seconds(0.1), seconds(0.5), seconds(1.1)]
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
