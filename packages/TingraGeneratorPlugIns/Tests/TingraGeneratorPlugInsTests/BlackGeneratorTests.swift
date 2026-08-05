//
//  BlackGeneratorTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-08-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("BlackGenerator")
struct BlackGeneratorTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 320

    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let height = 180

    /// Collects every frame the generator produces for the scripted ticks.
    private func collectFrames(tickTimes: [CMTime]) async -> [CapturedFrame] {
        let generator = BlackGenerator(
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

    @Test("every pixel is black at full alpha — a transparent frame would show the layers beneath")
    func everyPixelIsOpaqueBlack() async throws {
        let frames = await collectFrames(tickTimes: [.zero])

        let buffer = try #require(frames.first?.pixelBuffer)
        let pixels = try Self.pixels(of: buffer)
        try #require(pixels.count == Self.width * Self.height)
        #expect(pixels.allSatisfy { $0.blue == 0 && $0.green == 0 && $0.red == 0 })
        #expect(pixels.allSatisfy { $0.alpha == 255 })
    }

    @Test("the corners are black too, so the fill covers the whole frame rather than a sub-rect")
    func fillCoversEveryCorner() async throws {
        let frames = await collectFrames(tickTimes: [.zero])

        let buffer = try #require(frames.first?.pixelBuffer)
        let corners = [
            (0, 0),
            (Self.width - 1, 0),
            (0, Self.height - 1),
            (Self.width - 1, Self.height - 1),
        ]
        for (x, y) in corners {
            let pixel = try Self.pixel(atX: x, y: y, of: buffer)
            #expect(pixel.blue == 0 && pixel.green == 0 && pixel.red == 0 && pixel.alpha == 255)
        }
    }

    @Test("every frame over a long run is opaque black, including pool-recycled buffers")
    func everyFrameStaysOpaqueBlack() async throws {
        // Each frame is checked and then **dropped**, so the pool actually
        // recycles: it only reuses a buffer once its previous holder
        // releases it, and a test that retains every frame (as
        // `collectFrames` does) never receives a recycled buffer at all.
        //
        // Note what this can and cannot prove. It cannot prove the fill runs
        // per tick — for a *black* generator a stale recycled buffer still
        // holds black, so filling once would look identical here. What it
        // does cover is every frame of a long run being fully opaque black
        // across both fresh and recycled buffers; the per-tick fill is what
        // keeps that true if this file ever renders anything but black, and
        // `everyPixelIsOpaqueBlack` is what fails outright if the fill is
        // dropped (a never-filled buffer reads alpha 0, not 255).
        let ticks = (0..<24).map { CMTime(value: Int64($0), timescale: 30) }
        let generator = BlackGenerator(
            clock: SyntheticClock(tickTimes: ticks),
            width: Self.width,
            height: Self.height,
            frameRate: 30
        )

        var checked = 0
        for await frame in generator.frames() {
            let pixels = try Self.pixels(of: frame.pixelBuffer)
            #expect(pixels.allSatisfy { $0.blue == 0 && $0.green == 0 && $0.red == 0 && $0.alpha == 255 })
            checked += 1
        }

        #expect(checked == ticks.count)
    }

    @Test("every frame is a distinct buffer, so a consumer holding one is never written under")
    func eachFrameIsItsOwnBuffer() async throws {
        let ticks = [CMTime.zero, CMTime(value: 1, timescale: 30), CMTime(value: 2, timescale: 30)]

        let frames = await collectFrames(tickTimes: ticks)

        try #require(frames.count == 3)
        // The frames are all retained here at once, so the pool cannot have
        // recycled one into another — the frame ownership rule
        // (ARCHITECTURE.md) requires a yielded buffer to stay stable for its
        // holder.
        let identities = frames.map { ObjectIdentifier($0.pixelBuffer) }
        #expect(Set(identities).count == 3)
    }

    @Test("stop() finishes a live frame stream")
    func stopFinishesStream() async {
        let generator = BlackGenerator(
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

    @Test("the generator carries its stable identifier, name, kind, and media")
    func identity() {
        let generator = BlackGenerator(clock: SyntheticClock())
        #expect(generator.id == BlackGenerator.inputID)
        #expect(generator.id == InputID(rawValue: "black"))
        #expect(generator.name == "Black")
        #expect(generator.kind == .generator)
        // A picture, however plain — the kind cannot say so, which is why a
        // black generator can become a layer at all.
        #expect(generator.media == .video)
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

    /// Reads every visible BGRA pixel from a locked copy of the buffer,
    /// skipping any row padding the pool added.
    private static func pixels(
        of buffer: CVPixelBuffer
    ) throws -> [(blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var result: [(blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)] = []
        result.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let pointer = bytes + y * rowBytes + x * 4
                result.append((pointer[0], pointer[1], pointer[2], pointer[3]))
            }
        }
        return result
    }
}
