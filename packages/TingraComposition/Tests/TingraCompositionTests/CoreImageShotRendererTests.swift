//
//  CoreImageShotRendererTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreMedia
import CoreVideo
import Testing
import TingraPlugInKit

@testable import TingraComposition

/// One BGRA pixel read back from a buffer.
private struct Pixel: Equatable {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
    let alpha: UInt8
}

/// Creates a solid-color `width`×`height` 32BGRA buffer for use as an input
/// frame. Color components are `0`...`255`, straight (non-premultiplied).
private func makeSolidBuffer(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CVPixelBuffer {
    var bufferOut: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
        &bufferOut
    )
    let buffer = bufferOut!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            base[offset] = blue
            base[offset + 1] = green
            base[offset + 2] = red
            base[offset + 3] = 255
        }
    }
    return buffer
}

/// Reads back one pixel (row `y` from the top, column `x`) as BGRA.
private func readPixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> Pixel {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let offset = y * bytesPerRow + x * 4
    return Pixel(blue: base[offset], green: base[offset + 1], red: base[offset + 2], alpha: base[offset + 3])
}

@Suite("CoreImageShotRenderer")
struct CoreImageShotRendererTests {
    /// A renderer over a software Core Image context: deterministic and
    /// GPU-free, so the compositing math is checked the same on any runner.
    private func makeRenderer() -> CoreImageShotRenderer {
        CoreImageShotRenderer(context: CIContext(options: [.useSoftwareRenderer: true]))
    }

    /// A frame around a solid-color input buffer.
    private func solidFrame(red: UInt8, green: UInt8, blue: UInt8) -> CapturedFrame {
        CapturedFrame(
            pixelBuffer: makeSolidBuffer(width: 4, height: 4, red: red, green: green, blue: blue),
            presentationTime: .zero
        )
    }

    @Test("an empty shot renders the background color across the program frame")
    func emptyShotRendersBackground() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)

        let program = try #require(
            renderer.render(shot: Shot(background: .black), frames: [:], format: format, time: .zero)
        )

        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.red == 0)
        #expect(pixel.green == 0)
        #expect(pixel.blue == 0)
    }

    @Test("a full-frame opaque layer fills the program with the input's color")
    func fullFrameLayerFillsProgram() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let shot = Shot(layers: [Layer(input: camera)])

        let program = try #require(
            renderer.render(
                shot: shot,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: CMTime(value: 5, timescale: 30)
            )
        )

        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.red > 250)
        #expect(pixel.green < 5)
        #expect(pixel.blue < 5)
        #expect(program.presentationTime == CMTime(value: 5, timescale: 30))
    }

    @Test("a layer's normalized top-left frame places it in the top-left of the program (Y-flip correct)")
    func layerPlacementRespectsTopLeftOrigin() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        // Top-left quadrant in top-left-origin normalized coordinates.
        let shot = Shot(
            layers: [Layer(input: camera, frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))],
            background: .black
        )

        let program = try #require(
            renderer.render(
                shot: shot,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: .zero
            )
        )

        // The top-left pixel is inside the layer (red); the bottom-right
        // pixel is outside it (background black).
        let topLeft = readPixel(program.pixelBuffer, x: 0, y: 0)
        let bottomRight = readPixel(program.pixelBuffer, x: 3, y: 3)
        #expect(topLeft.red > 250)
        #expect(bottomRight.red < 5)
    }

    @Test("a reduced-opacity layer over black darkens toward the background")
    func opacityBlendsTowardBackground() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let opaque = Shot(layers: [Layer(input: camera, opacity: 1)])
        let faded = Shot(layers: [Layer(input: camera, opacity: 0.5)])
        let white = solidFrame(red: 255, green: 255, blue: 255)

        let opaqueProgram = try #require(
            renderer.render(shot: opaque, frames: [camera: white], format: format, time: .zero)
        )
        let fadedProgram = try #require(
            renderer.render(shot: faded, frames: [camera: white], format: format, time: .zero)
        )

        let opaquePixel = readPixel(opaqueProgram.pixelBuffer, x: 2, y: 2)
        let fadedPixel = readPixel(fadedProgram.pixelBuffer, x: 2, y: 2)
        // Fully opaque white is near max; the faded layer sits between the
        // white layer and the black background (no exact value asserted —
        // Core Image composites in linear space).
        #expect(opaquePixel.red > 250)
        #expect(fadedPixel.red < opaquePixel.red)
        #expect(fadedPixel.red > 0)
    }

    @Test("the program frame is tagged BT.709 — no untagged buffer leaves the renderer")
    func programFrameIsTagged() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)

        let program = try #require(
            renderer.render(shot: Shot(), frames: [:], format: format, time: .zero)
        )

        let primaries = CVBufferCopyAttachment(program.pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
        #expect(primaries as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    }

    @Test("a dissolve at progress 0 renders the outgoing shot alone")
    func dissolveAtZeroProgressRendersOutgoingAlone() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let red = Shot(layers: [Layer(input: camera)], background: .black)
        let blue = Shot(background: .black)

        let program = try #require(
            renderer.renderDissolve(
                from: red,
                to: blue,
                progress: 0,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: .zero
            )
        )

        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.red > 250)
        #expect(pixel.blue < 5)
    }

    @Test("a dissolve at progress 1 renders the incoming shot alone")
    func dissolveAtFullProgressRendersIncomingAlone() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let outgoing = Shot(background: .black)
        let incoming = Shot(layers: [Layer(input: camera)], background: .black)

        let program = try #require(
            renderer.renderDissolve(
                from: outgoing,
                to: incoming,
                progress: 1,
                frames: [camera: solidFrame(red: 0, green: 0, blue: 255)],
                format: format,
                time: .zero
            )
        )

        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.blue > 250)
        #expect(pixel.red < 5)
    }

    @Test("a dissolve midway blends between the outgoing and incoming shot")
    func dissolveMidwayBlendsBothShots() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let outgoing = Shot(layers: [Layer(input: camera)], background: .black)
        let incoming = Shot(background: .black)
        let white = solidFrame(red: 255, green: 255, blue: 255)

        let program = try #require(
            renderer.renderDissolve(
                from: outgoing,
                to: incoming,
                progress: 0.5,
                frames: [camera: white],
                format: format,
                time: .zero
            )
        )

        // Halfway between an opaque white outgoing layer and a black
        // incoming background: dimmer than fully outgoing, brighter than
        // fully incoming (the same "toward the background" fade as layer
        // opacity, applied to the whole incoming image).
        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.red < 250)
        #expect(pixel.red > 0)
    }

    @Test("the program frame stamped by a dissolve carries the tick's time")
    func dissolveStampsTickTime() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)

        let program = try #require(
            renderer.renderDissolve(
                from: Shot(),
                to: Shot(),
                progress: 0.5,
                frames: [:],
                format: format,
                time: CMTime(value: 7, timescale: 30)
            )
        )

        #expect(program.presentationTime == CMTime(value: 7, timescale: 30))
    }
}
