//
//  PlugeGeneratorTests.swift
//  TingraGeneratorPlugIns
//
//  Created by GitHub Copilot on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("PlugeGenerator")
struct PlugeGeneratorTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 320

    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let height = 180

    /// Collects every frame the generator produces for the scripted ticks.
    private func collectFrames(tickTimes: [CMTime]) async -> [CapturedFrame] {
        let generator = PlugeGenerator(
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

    @Test("the background sits at reference black while the PLUGE trio steps below and above it")
    func blackLevelBarsStepAsExpected() async throws {
        let frames = await collectFrames(tickTimes: [.zero])

        let buffer = try #require(frames.first?.pixelBuffer)
        let background = try Self.pixel(atX: 4, y: 4, of: buffer)
        let barsMidY = Self.pixelY(fromDrawnFraction: 0.73)
        let barsMinX = Double(Self.width) * 0.34
        let barsWidth = Double(Self.width) * 0.32
        let gap = barsWidth * 0.04
        let barWidth = (barsWidth - gap * 2) / 3
        let belowBlack = try Self.pixel(atX: Int(barsMinX + barWidth / 2), y: barsMidY, of: buffer)
        let referenceBlack = try Self.pixel(atX: Int(barsMinX + barWidth + gap + barWidth / 2), y: barsMidY, of: buffer)
        let aboveBlack = try Self.pixel(
            atX: Int(barsMinX + (barWidth + gap) * 2 + barWidth / 2), y: barsMidY, of: buffer)

        #expect(abs(Int(background.blue) - 16) <= 1)
        #expect(abs(Int(referenceBlack.blue) - 16) <= 1)
        #expect(Int(belowBlack.blue) < Int(referenceBlack.blue))
        #expect(Int(aboveBlack.blue) > Int(referenceBlack.blue))
    }

    @Test("the shadow ramp gets brighter from left to right")
    func shadowRampBrightensAcrossTheFrame() async throws {
        let frames = await collectFrames(tickTimes: [.zero])

        let buffer = try #require(frames.first?.pixelBuffer)
        let rampMidY = Self.pixelY(fromDrawnFraction: 0.35)
        let left = try Self.pixel(atX: Int(Double(Self.width) * 0.18), y: rampMidY, of: buffer)
        let right = try Self.pixel(atX: Int(Double(Self.width) * 0.80), y: rampMidY, of: buffer)

        #expect(Int(left.blue) > 16)
        #expect(Int(right.blue) > Int(left.blue))
    }

    @Test("stop() finishes a live frame stream")
    func stopFinishesStream() async {
        let generator = PlugeGenerator(
            clock: SyntheticClock(staysOpen: true),
            width: Self.width,
            height: Self.height,
            frameRate: 30
        )
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

    @Test("the generator carries its stable identifier, name, and kind")
    func identity() {
        let generator = PlugeGenerator(clock: SyntheticClock())
        #expect(generator.id == PlugeGenerator.inputID)
        #expect(generator.id == InputID(rawValue: "pluge"))
        #expect(generator.name == "PLUGE")
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

    /// Converts a drawing-space vertical fraction (origin at the bottom,
    /// matching Core Graphics) into a pixel-buffer row index (origin at the
    /// top, matching the raw buffer bytes the tests inspect).
    private static func pixelY(fromDrawnFraction fraction: Double) -> Int {
        let maxIndex = Double(Self.height - 1)
        return Int((maxIndex * (1 - fraction)).rounded(.down))
    }
}
