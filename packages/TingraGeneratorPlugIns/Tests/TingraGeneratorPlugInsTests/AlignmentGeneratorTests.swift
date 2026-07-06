//
//  AlignmentGeneratorTests.swift
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

@Suite("AlignmentGenerator")
struct AlignmentGeneratorTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 320

    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let height = 180

    /// Collects every frame the generator produces for the scripted ticks.
    private func collectFrames(tickTimes: [CMTime]) async -> [CapturedFrame] {
        let generator = AlignmentGenerator(
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

    @Test("the cached pattern stays visually identical across ticks")
    func cachedPatternStaysStatic() async throws {
        let frames = await collectFrames(tickTimes: [.zero, CMTime(value: 61, timescale: 1)])

        try #require(frames.count == 2)
        let first = try Self.bytes(of: frames[0].pixelBuffer)
        let second = try Self.bytes(of: frames[1].pixelBuffer)
        #expect(first == second)
    }

    @Test("the center cross is brighter than the dark background field")
    func centerCrossStandsOut() async throws {
        let frames = await collectFrames(tickTimes: [.zero])

        let buffer = try #require(frames.first?.pixelBuffer)
        let center = try Self.pixel(atX: Self.width / 2, y: Self.height / 2, of: buffer)
        let background = try Self.pixel(
            atX: Int(Double(Self.width) * 0.15), y: Int(Double(Self.height) * 0.15), of: buffer)
        #expect(Int(center.blue) > Int(background.blue))
    }

    @Test("stop() finishes a live frame stream")
    func stopFinishesStream() async {
        let generator = AlignmentGenerator(
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
        let generator = AlignmentGenerator(clock: SyntheticClock())
        #expect(generator.id == AlignmentGenerator.inputID)
        #expect(generator.id == InputID(rawValue: "alignment"))
        #expect(generator.name == "Alignment Pattern")
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
