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
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("BarsGenerator")
struct BarsGeneratorTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 322
    private static let height = 180

    /// Collects every frame the generator produces for the scripted ticks.
    private func collectFrames(tickTimes: [CMTime]) async -> [CapturedFrame] {
        let generator = BarsGenerator(
            clock: SyntheticClock(tickTimes: tickTimes),
            width: Self.width,
            height: Self.height,
            frameRate: 30
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

    /// The timecode for a whole number of seconds at the default frame base.
    private func timecode(seconds: Double) -> String {
        BarsTimecode.string(
            at: CMTime(seconds: seconds, preferredTimescale: 600),
            frameRate: Self.frameRate
        )
    }

    @Test("the session start reads as all zeroes")
    func startOfSession() {
        #expect(timecode(seconds: 0) == "00:00:00:00")
    }

    @Test("each field advances at its own base")
    func fieldsAdvance() {
        #expect(timecode(seconds: 0.5) == "00:00:00:15")
        #expect(timecode(seconds: 1) == "00:00:01:00")
        #expect(timecode(seconds: 61) == "00:01:01:00")
        #expect(timecode(seconds: 3661) == "01:01:01:00")
    }

    @Test("the last moment before a day reads 23:59:59:29")
    func lastFrameOfTheDay() {
        let almostADay = 24.0 * 3600 - 1.0 / 30
        #expect(timecode(seconds: almostADay) == "23:59:59:29")
    }

    @Test("hours wrap at 24, the SMPTE convention")
    func hoursWrapAtTwentyFour() {
        #expect(timecode(seconds: 24 * 3600) == "00:00:00:00")
        #expect(timecode(seconds: 25 * 3600) == "01:00:00:00")
        // The old modulus put this at 47:00:00:00 — a two-digit hours field
        // that matched neither SMPTE nor a plain elapsed count.
        #expect(timecode(seconds: 47 * 3600) == "23:00:00:00")
        #expect(timecode(seconds: 48 * 3600) == "00:00:00:00")
    }

    @Test("a time before zero clamps to the session start rather than going negative")
    func negativeTimeClamps() {
        #expect(timecode(seconds: -5) == "00:00:00:00")
    }

    @Test("every field is zero padded to two digits")
    func fieldsAreZeroPadded() {
        let value = timecode(seconds: 3661.1)
        #expect(value.count == 11)
        #expect(value.split(separator: ":").allSatisfy { $0.count == 2 })
    }

    @Test("the frame field counts to the frame base and no further")
    func frameFieldRespectsTheFrameBase() {
        let sixty = BarsTimecode.string(at: CMTime(seconds: 1.5, preferredTimescale: 600), frameRate: 60)
        #expect(sixty == "00:00:01:30")
        let twentyFive = BarsTimecode.string(at: CMTime(seconds: 0.96, preferredTimescale: 600), frameRate: 25)
        #expect(twentyFive == "00:00:00:24")
    }
}
