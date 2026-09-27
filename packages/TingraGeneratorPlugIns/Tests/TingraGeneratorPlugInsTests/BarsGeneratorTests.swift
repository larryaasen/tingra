//
//  BarsGeneratorTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("BarsGenerator")
struct BarsGeneratorTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 322
    private static let height = 180

    /// A fixed wall clock reading, so every frame's burned in time of day is
    /// the same run to run: 2026-09-27 12:00:00 UTC.
    private static let noon = Date(timeIntervalSince1970: 1_790_510_400)

    /// Collects every frame the generator produces for the scripted ticks,
    /// against a fixed wall clock in UTC.
    ///
    /// - Parameters:
    ///   - tickTimes: The ticks to render.
    ///   - wallNow: The wall clock's reading.
    /// - Returns: The frames.
    private func collectFrames(tickTimes: [CMTime], wallNow: Date = noon) async -> [CapturedFrame] {
        let generator = BarsGenerator(
            clock: SyntheticClock(tickTimes: tickTimes),
            width: Self.width,
            height: Self.height,
            frameRate: 30,
            wallClock: { wallNow },
            timeZone: .gmt
        )
        var frames: [CapturedFrame] = []
        for await frame in generator.frames() {
            frames.append(frame)
        }
        return frames
    }

    @Test("one frame per clock tick, stamped with the tick's master clock time")
    func oneFramePerTickWithTickPTS() async {
        let ticks = [CMTime.zero, CMTime(value: 1, timescale: 30), CMTime(value: 2, timescale: 30)]

        let frames = await collectFrames(tickTimes: ticks)

        #expect(frames.map(\.presentationTime) == ticks)
    }

    @Test("frames are IOSurface-backed 32BGRA in the working format")
    func framesAreWorkingFormat() async throws {
        let frames = await collectFrames(tickTimes: [.zero])

        let buffer = try #require(frames.first?.pixelBuffer)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        #expect(CVPixelBufferGetWidth(buffer) == Self.width)
        #expect(CVPixelBufferGetHeight(buffer) == Self.height)
    }

    @Test("every frame carries the BT.709 color attachments — an untagged buffer is a defect")
    func framesAreTaggedBT709() async throws {
        let frames = await collectFrames(tickTimes: [.zero])

        let buffer = try #require(frames.first?.pixelBuffer)
        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil)
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        #expect(primaries as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(transfer as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        #expect(matrix as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    @Test("the top-left pixel is the first SMPTE bar, 75% gray")
    func topLeftPixelIsGrayBar() async throws {
        let frames = await collectFrames(tickTimes: [.zero])

        let buffer = try #require(frames.first?.pixelBuffer)
        let pixel = try Self.pixel(atX: 0, y: 0, of: buffer)
        // 75% of full scale is 191.25; allow for the context's rounding.
        #expect(abs(Int(pixel.blue) - 191) <= 2)
        #expect(abs(Int(pixel.green) - 191) <= 2)
        #expect(abs(Int(pixel.red) - 191) <= 2)
        #expect(pixel.alpha == 255)
    }

    @Test("frames at different times differ — the burned in timecode changes")
    func timecodeChangesBetweenFrames() async throws {
        let frames = await collectFrames(tickTimes: [.zero, CMTime(value: 61, timescale: 1)])

        try #require(frames.count == 2)
        let first = try Self.bytes(of: frames[0].pixelBuffer)
        let second = try Self.bytes(of: frames[1].pixelBuffer)
        #expect(first != second)
    }

    @Test("the same tick against the same wall clock draws the same frame")
    func sameWallClockDrawsSameFrame() async throws {
        let first = try #require(await collectFrames(tickTimes: [.zero]).first)
        let second = try #require(await collectFrames(tickTimes: [.zero]).first)

        #expect(try Self.bytes(of: first.pixelBuffer) == Self.bytes(of: second.pixelBuffer))
    }

    @Test("the burned in time of day follows the wall clock, not the master clock")
    func timeOfDayFollowsWallClock() async throws {
        let noon = try #require(await collectFrames(tickTimes: [.zero]).first)
        let later = try #require(
            await collectFrames(tickTimes: [.zero], wallNow: Self.noon.addingTimeInterval(3600)).first)

        #expect(noon.presentationTime == later.presentationTime)
        #expect(try Self.bytes(of: noon.pixelBuffer) != Self.bytes(of: later.pixelBuffer))
    }

    @Test("stop() finishes a live frame stream")
    func stopFinishesStream() async {
        let generator = BarsGenerator(
            clock: SyntheticClock(staysOpen: true),
            width: Self.width,
            height: Self.height,
            frameRate: 30
        )
        // Create the stream first — AsyncStream registers its continuation
        // at construction, so the stop below reliably finds it.
        let frames = generator.frames()
        let consumer = Task {
            var count = 0
            for await _ in frames {
                count += 1
            }
            return count
        }

        await generator.stop()

        // The consumer completing at all is the assertion — without the
        // stop, the open synthetic clock would keep the stream live.
        #expect(await consumer.value == 0)
    }

    @Test("the generator carries its stable identifier, name, and kind")
    func identity() {
        let generator = BarsGenerator(clock: SyntheticClock())
        #expect(generator.id == BarsGenerator.inputID)
        #expect(generator.id == InputID(rawValue: "bars"))
        #expect(generator.name == "SMPTE Bars")
        #expect(generator.kind == .generator)
    }

    /// Reads one BGRA pixel from a locked copy of the buffer.
    private static func pixel(
        atX x: Int,
        y: Int,
        of buffer: CVPixelBuffer
    ) throws -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self) + y * rowBytes + x * 4
        return (pointer[0], pointer[1], pointer[2], pointer[3])
    }

    /// Copies the buffer's visible pixel bytes row by row (excluding row
    /// padding) for whole-frame comparisons.
    private static func bytes(of buffer: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for row in 0..<height {
            bytes.append(contentsOf: UnsafeBufferPointer(start: pointer + row * rowBytes, count: width * 4))
        }
        return bytes
    }
}

@Suite("BarsTimecode")
struct BarsTimecodeTests {
    /// The generator's default frame base.
    private static let frameRate = 30

    /// New York, whose clocks change for daylight saving.
    private static let newYork = TimeZone(identifier: "America/New_York")

    /// The moment a New York clock reads the given time on 2026-09-27.
    ///
    /// - Parameters:
    ///   - hour: The hour.
    ///   - minute: The minute.
    ///   - second: The second, with any fraction.
    ///   - day: The day of the month (default the 27th).
    ///   - month: The month (default September).
    /// - Returns: The moment.
    private func newYork(
        _ hour: Int, _ minute: Int, _ second: Double, day: Int = 27, month: Int = 9
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(Self.newYork)
        let whole = try #require(
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
        return whole.addingTimeInterval(second)
    }

    /// The timecode for a moment on a New York clock at the default frame base.
    private func timecode(_ date: Date) throws -> String {
        BarsTimecode.string(for: date, frameRate: Self.frameRate, timeZone: try #require(Self.newYork))
    }

    @Test("midnight reads as all zeroes")
    func midnight() throws {
        #expect(try timecode(newYork(0, 0, 0)) == "00:00:00:00")
    }

    @Test("each field reads the zone's clock, the frame counted within the second")
    func fieldsReadTheClock() throws {
        #expect(try timecode(newYork(13, 45, 7.5)) == "13:45:07:15")
        #expect(try timecode(newYork(7, 49, 0)) == "07:49:00:00")
    }

    @Test("the last frame before midnight reads 23:59:59:29")
    func lastFrameOfTheDay() throws {
        #expect(try timecode(newYork(23, 59, 59 + 29.5 / 30)) == "23:59:59:29")
    }

    @Test("one moment reads each zone's own hour")
    func zonesReadTheirOwnHour() throws {
        let moment = try newYork(7, 49, 0)
        let utc = BarsTimecode.string(for: moment, frameRate: Self.frameRate, timeZone: .gmt)

        // New York is four hours behind UTC in September (daylight time).
        #expect(utc == "11:49:00:00")
    }

    @Test("after the spring daylight-saving change the hour is the clock's, not the time elapsed since midnight")
    func daylightSavingHourIsTheClocks() throws {
        // 2026-03-08: New York's clocks jump from 02:00 to 03:00, so 03:30
        // on the clock is only 2.5 hours after midnight.
        #expect(try timecode(newYork(3, 30, 0, day: 8, month: 3)) == "03:30:00:00")
    }

    @Test("every field is zero padded to two digits")
    func fieldsAreZeroPadded() throws {
        let value = try timecode(newYork(1, 2, 3.1))
        #expect(value == "01:02:03:03")
        #expect(value.split(separator: ":").allSatisfy { $0.count == 2 })
    }

    @Test("the frame field counts to the frame base and no further")
    func frameFieldRespectsTheFrameBase() throws {
        let zone = try #require(Self.newYork)
        #expect(BarsTimecode.string(for: try newYork(0, 0, 1.5), frameRate: 60, timeZone: zone) == "00:00:01:30")
        #expect(BarsTimecode.string(for: try newYork(0, 0, 0.96), frameRate: 25, timeZone: zone) == "00:00:00:24")
        #expect(BarsTimecode.string(for: try newYork(0, 0, 0.9999999), frameRate: 30, timeZone: zone) == "00:00:00:29")
    }

    @Test("a master clock time stands for the wall clock moved by its distance from the master clock now")
    func timeOfDayMapsTheMasterClock() {
        let wallNow = Date(timeIntervalSince1970: 1_790_510_400)
        let clockNow = CMTime(value: 1_140_250, timescale: 1)

        let ahead = BarsTimecode.timeOfDay(
            at: CMTimeAdd(clockNow, CMTime(value: 2, timescale: 1)), clockNow: clockNow, wallNow: wallNow)
        let behind = BarsTimecode.timeOfDay(
            at: CMTimeSubtract(clockNow, CMTime(value: 1, timescale: 30)), clockNow: clockNow, wallNow: wallNow)

        #expect(ahead == wallNow.addingTimeInterval(2))
        // A date this far from its 2001 reference resolves to about 0.1 µs.
        #expect(abs(behind.timeIntervalSince(wallNow) + 1.0 / 30) < 1e-6)
    }
}
