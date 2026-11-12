//
//  TimeStampGeneratorTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("TimeStampGenerator")
struct TimeStampGeneratorTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 320

    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let height = 180

    /// UTC, so the fixed wall clock reads the same on every Mac.
    private static let utc = TimeZone(secondsFromGMT: 0) ?? .gmt

    /// 2026-11-11 14:05:09 UTC, the fixed wall clock.
    private static let wallNow = Date(timeIntervalSince1970: 1_794_405_909)

    /// A generator on a settable clock and the fixed wall clock.
    private static func makeGenerator(clock: any EngineClock) -> TimeStampGenerator {
        TimeStampGenerator(
            clock: clock,
            width: width,
            height: height,
            frameRate: 30,
            wallClock: { wallNow },
            timeZone: utc
        )
    }

    @Test("the generator carries its stable identifier, name, kind, and media")
    func identity() {
        let generator = TimeStampGenerator(clock: SyntheticClock())

        #expect(generator.id == TimeStampGenerator.inputID)
        #expect(generator.id == InputID(rawValue: "time-stamp"))
        #expect(generator.name == "Time Stamp")
        #expect(generator.kind == .generator)
        #expect(generator.media == .video)
    }

    @Test("it declares the format toggles, then the shared appearance")
    func declaresParameters() {
        let parameters = TimeStampGenerator(clock: SyntheticClock()).parameters

        #expect(
            parameters.map(\.key) == [
                "showsDate", "showsSeconds", "twelveHour", "position", "sizePercent", "textColor", "background",
            ])
        #expect(parameters.prefix(3).allSatisfy { $0.kind == .toggle })
        #expect(Set(parameters.map(\.key)).count == parameters.count)
    }

    @Test("by default it shows the date and a 24-hour time with seconds, small, in the bottom right corner")
    func defaults() {
        let settings = TimeStampGenerator(clock: SyntheticClock()).currentSettings

        #expect(settings.format == TimeStampFormat(showsDate: true, showsSeconds: true, usesTwelveHourClock: false))
        #expect(settings.style.position == .bottomRight)
        #expect(settings.style.sizeFraction == 0.05)
    }

    @Test("a tick at the master clock's now shows the wall clock's now")
    func tickAtNowShowsWallNow() {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(5000)))

        #expect(generator.text(at: seconds(5000)) == "2026-11-11 14:05:09")
    }

    @Test("a tick away from now shows the wall-clock moment it stands for, not the master clock's own time")
    func tickIsPlacedOnTheWallClock() {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(5000)))

        #expect(generator.text(at: seconds(5002)) == "2026-11-11 14:05:11")
        #expect(generator.text(at: seconds(4999)) == "2026-11-11 14:05:08")
        // 9 h 54 m 51 s later is midnight, and the date rolls over with it.
        #expect(generator.text(at: seconds(5000 + 35_691)) == "2026-11-12 00:00:00")
    }

    @Test("setParameters changes the format live")
    func setParametersChangesFormat() async {
        let generator = Self.makeGenerator(clock: SettableClock(now: seconds(5000)))

        await generator.setParameters(["showsDate": .bool(false)])
        #expect(generator.text(at: seconds(5000)) == "14:05:09")

        await generator.setParameters(["showsDate": .bool(false), "showsSeconds": .bool(false)])
        #expect(generator.text(at: seconds(5000)) == "14:05")

        await generator.setParameters(["twelveHour": .bool(true)])
        #expect(generator.text(at: seconds(5000)) == "2026-11-11 2:05:09 PM")
    }

    @Test("setParameters applies the appearance, and an empty payload restores the defaults")
    func setParametersAppliesAppearanceAndDefaults() async {
        let generator = Self.makeGenerator(clock: SettableClock())
        let defaults = generator.currentSettings

        await generator.setParameters(["position": .double(0), "sizePercent": .double(12), "showsDate": .bool(false)])
        #expect(generator.currentSettings.style.position == .center)
        #expect(generator.currentSettings.style.sizeFraction == 0.12)
        #expect(generator.currentSettings != defaults)

        await generator.setParameters([:])
        #expect(generator.currentSettings == defaults)
    }

    @Test("a key the generator does not declare is ignored")
    func undeclaredKeysAreIgnored() async {
        let generator = Self.makeGenerator(clock: SettableClock())
        let defaults = generator.currentSettings

        await generator.setParameters(["frequencyHertz": .double(1000), "showsDate": .string("yes")])

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

    @Test("frames are in the working format and transparent outside the stamp, which sits bottom right")
    func framesAreTransparentWithTheStampInItsCorner() async throws {
        let generator = Self.makeGenerator(clock: SyntheticClock(tickTimes: [.zero]))

        var frames: [CapturedFrame] = []
        for await frame in generator.frames() {
            frames.append(frame)
        }

        let buffer = try #require(frames.first?.pixelBuffer)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        #expect(CVPixelBufferGetWidth(buffer) == Self.width)
        #expect(CVPixelBufferGetHeight(buffer) == Self.height)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) != nil)
        let pixels = try bgraPixels(of: buffer)
        #expect(pixels.first?.alpha == 0)
        let bounds = try #require(try inkBounds(of: buffer))
        #expect(bounds.minX > Self.width / 2)
        #expect(bounds.minY > Self.height / 2)
    }

    @Test("frames within one second share a buffer; the next second gets a new one")
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

@Suite("TimeStampFormat")
struct TimeStampFormatTests {
    /// UTC, so the fixed moments read the same on every Mac.
    private static let utc = TimeZone(secondsFromGMT: 0) ?? .gmt

    /// 2026-11-11 14:05:09 UTC.
    private static let afternoon = Date(timeIntervalSince1970: 1_794_405_909)

    /// The full format: date, 24-hour time, seconds.
    private static let full = TimeStampFormat(showsDate: true, showsSeconds: true, usesTwelveHourClock: false)

    @Test("the full stamp is year-month-day and a 24-hour time with seconds")
    func fullStamp() {
        #expect(Self.full.string(for: Self.afternoon, timeZone: Self.utc) == "2026-11-11 14:05:09")
    }

    @Test("the date and the seconds drop out as the format says")
    func partsDropOut() {
        var format = Self.full
        format.showsDate = false
        #expect(format.string(for: Self.afternoon, timeZone: Self.utc) == "14:05:09")
        format.showsSeconds = false
        #expect(format.string(for: Self.afternoon, timeZone: Self.utc) == "14:05")
        format.showsDate = true
        #expect(format.string(for: Self.afternoon, timeZone: Self.utc) == "2026-11-11 14:05")
    }

    @Test("a 12-hour clock reads midnight and noon as 12, with AM and PM")
    func twelveHourClock() {
        let format = TimeStampFormat(showsDate: false, showsSeconds: false, usesTwelveHourClock: true)
        let midnight = Date(timeIntervalSince1970: 1_794_355_200)

        #expect(format.string(for: midnight, timeZone: Self.utc) == "12:00 AM")
        #expect(format.string(for: midnight.addingTimeInterval(9 * 3600 + 7 * 60), timeZone: Self.utc) == "9:07 AM")
        #expect(format.string(for: midnight.addingTimeInterval(12 * 3600), timeZone: Self.utc) == "12:00 PM")
        #expect(format.string(for: midnight.addingTimeInterval(23 * 3600 + 59 * 60), timeZone: Self.utc) == "11:59 PM")
    }

    @Test("the stamp reads the given zone's calendar and clock, so the date can differ from UTC's")
    func readsTheZone() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let lateEvening = Date(timeIntervalSince1970: 1_794_355_200 + 22 * 3600)

        #expect(Self.full.string(for: lateEvening, timeZone: Self.utc) == "2026-11-11 22:00:00")
        #expect(Self.full.string(for: lateEvening, timeZone: tokyo) == "2026-11-12 07:00:00")
        #expect(Self.full.string(for: lateEvening, timeZone: losAngeles) == "2026-11-11 14:00:00")
    }

    @Test("formats that differ in any part are not equal")
    func formatsCompareByValue() {
        var other = Self.full
        other.usesTwelveHourClock = true

        #expect(Self.full == TimeStampFormat(showsDate: true, showsSeconds: true, usesTwelveHourClock: false))
        #expect(Self.full != other)
    }
}
