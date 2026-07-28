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
import Synchronization
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

    @Test("a wipe at progress 0 renders the outgoing shot alone")
    func wipeAtZeroProgressRendersOutgoingAlone() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let red = Shot(layers: [Layer(input: camera)], background: .black)
        let black = Shot(background: .black)

        let program = try #require(
            renderer.renderWipe(
                from: red,
                to: black,
                edge: .left,
                progress: 0,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: .zero
            )
        )

        // Every pixel is still the outgoing shot — the reveal has not
        // entered the frame.
        for x in [0, 3] {
            let pixel = readPixel(program.pixelBuffer, x: x, y: 2)
            #expect(pixel.red > 250)
        }
    }

    @Test("a wipe at progress 1 renders the incoming shot alone")
    func wipeAtFullProgressRendersIncomingAlone() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let outgoing = Shot(background: .black)
        let incoming = Shot(layers: [Layer(input: camera)], background: .black)

        let program = try #require(
            renderer.renderWipe(
                from: outgoing,
                to: incoming,
                edge: .left,
                progress: 1,
                frames: [camera: solidFrame(red: 0, green: 0, blue: 255)],
                format: format,
                time: .zero
            )
        )

        // Every pixel is the incoming shot — the reveal has crossed the
        // whole frame, feather included.
        for x in [0, 3] {
            let pixel = readPixel(program.pixelBuffer, x: x, y: 2)
            #expect(pixel.blue > 250)
            #expect(pixel.red < 5)
        }
    }

    @Test("a left-edge wipe midway shows the incoming shot on the left and the outgoing on the right")
    func leftEdgeWipeMidwayRevealsLeftSide() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let cameraA = InputID(rawValue: "cameraA")
        let cameraB = InputID(rawValue: "cameraB")
        let outgoing = Shot(layers: [Layer(input: cameraA)], background: .black)
        let incoming = Shot(layers: [Layer(input: cameraB)], background: .black)
        let frames = [
            cameraA: solidFrame(red: 255, green: 0, blue: 0),
            cameraB: solidFrame(red: 0, green: 0, blue: 255),
        ]

        let program = try #require(
            renderer.renderWipe(
                from: outgoing,
                to: incoming,
                edge: .left,
                progress: 0.5,
                frames: frames,
                format: format,
                time: .zero
            )
        )

        // The boundary sits mid-frame: the left column is revealed
        // (incoming blue), the right column is not yet (outgoing red);
        // columns near the soft boundary are deliberately not probed.
        let left = readPixel(program.pixelBuffer, x: 0, y: 2)
        let right = readPixel(program.pixelBuffer, x: 3, y: 2)
        #expect(left.blue > 250)
        #expect(left.red < 5)
        #expect(right.red > 250)
        #expect(right.blue < 5)
    }

    @Test("a top-edge wipe midway reveals the top of the frame (Y-flip correct)")
    func topEdgeWipeMidwayRevealsTopSide() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let cameraA = InputID(rawValue: "cameraA")
        let cameraB = InputID(rawValue: "cameraB")
        let outgoing = Shot(layers: [Layer(input: cameraA)], background: .black)
        let incoming = Shot(layers: [Layer(input: cameraB)], background: .black)
        let frames = [
            cameraA: solidFrame(red: 255, green: 0, blue: 0),
            cameraB: solidFrame(red: 0, green: 0, blue: 255),
        ]

        let program = try #require(
            renderer.renderWipe(
                from: outgoing,
                to: incoming,
                edge: .top,
                progress: 0.5,
                frames: frames,
                format: format,
                time: .zero
            )
        )

        // The top row (operator terms — row 0) is revealed, the bottom row
        // is not: the edge names follow the layer frames' top-left origin,
        // not Core Image's bottom-left one.
        let top = readPixel(program.pixelBuffer, x: 2, y: 0)
        let bottom = readPixel(program.pixelBuffer, x: 2, y: 3)
        #expect(top.blue > 250)
        #expect(top.red < 5)
        #expect(bottom.red > 250)
        #expect(bottom.blue < 5)
    }

    @Test(
        "a shader transition at progress 0 renders the outgoing shot alone — proof the kernel compiled and applied",
        arguments: TransitionShader.allCases
    )
    func shaderAtZeroProgressRendersOutgoingAlone(shader: TransitionShader) throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 16, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let outgoing = Shot(layers: [Layer(input: camera)], background: .black)
        let incoming = Shot(background: .black)

        let program = try #require(
            renderer.renderShader(
                from: outgoing,
                to: incoming,
                shader: shader,
                progress: 0,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: .zero
            )
        )

        // Every probed pixel is still the outgoing shot — the reveal has
        // not entered its span. This doubles as the compile check: a kernel
        // that did not build degrades to the *incoming* shot, which would
        // read black here.
        for (x, y) in [(0, 0), (3, 15), (2, 8)] {
            let pixel = readPixel(program.pixelBuffer, x: x, y: y)
            #expect(pixel.red > 250)
        }
    }

    @Test(
        "a shader transition at progress 1 renders the incoming shot alone",
        arguments: TransitionShader.allCases
    )
    func shaderAtFullProgressRendersIncomingAlone(shader: TransitionShader) throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 16, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let outgoing = Shot(background: .black)
        let incoming = Shot(layers: [Layer(input: camera)], background: .black)

        let program = try #require(
            renderer.renderShader(
                from: outgoing,
                to: incoming,
                shader: shader,
                progress: 1,
                frames: [camera: solidFrame(red: 0, green: 0, blue: 255)],
                format: format,
                time: .zero
            )
        )

        // Every probed pixel is the incoming shot — the reveal has crossed
        // its whole span, feather included.
        for (x, y) in [(0, 0), (3, 15), (2, 8)] {
            let pixel = readPixel(program.pixelBuffer, x: x, y: y)
            #expect(pixel.blue > 250)
            #expect(pixel.red < 5)
        }
    }

    @Test("an iris midway reveals the frame's center while its corners stay outgoing")
    func irisMidwayRevealsCenter() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let cameraA = InputID(rawValue: "cameraA")
        let cameraB = InputID(rawValue: "cameraB")
        let outgoing = Shot(layers: [Layer(input: cameraA)], background: .black)
        let incoming = Shot(layers: [Layer(input: cameraB)], background: .black)
        let frames = [
            cameraA: solidFrame(red: 255, green: 0, blue: 0),
            cameraB: solidFrame(red: 0, green: 0, blue: 255),
        ]

        let program = try #require(
            renderer.renderShader(
                from: outgoing,
                to: incoming,
                shader: .iris,
                progress: 0.5,
                frames: frames,
                format: format,
                time: .zero
            )
        )

        // The circular boundary sits mid-sweep: the center pixel is
        // revealed (incoming blue), the corners are not yet (outgoing red).
        let center = readPixel(program.pixelBuffer, x: 2, y: 2)
        let corner = readPixel(program.pixelBuffer, x: 0, y: 0)
        #expect(center.blue > 250)
        #expect(center.red < 5)
        #expect(corner.red > 250)
        #expect(corner.blue < 5)
    }

    @Test("a diagonal midway reveals from the screen's top-left corner toward the bottom-right (Y-flip correct)")
    func diagonalMidwayRevealsTopLeft() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let cameraA = InputID(rawValue: "cameraA")
        let cameraB = InputID(rawValue: "cameraB")
        let outgoing = Shot(layers: [Layer(input: cameraA)], background: .black)
        let incoming = Shot(layers: [Layer(input: cameraB)], background: .black)
        let frames = [
            cameraA: solidFrame(red: 255, green: 0, blue: 0),
            cameraB: solidFrame(red: 0, green: 0, blue: 255),
        ]

        let program = try #require(
            renderer.renderShader(
                from: outgoing,
                to: incoming,
                shader: .diagonal,
                progress: 0.5,
                frames: frames,
                format: format,
                time: .zero
            )
        )

        // The diagonal boundary sits mid-sweep: the top-left pixel
        // (operator terms — row 0) is revealed, the bottom-right is not —
        // the sweep opens from the screen's top-left, not Core Image's
        // bottom-left.
        let topLeft = readPixel(program.pixelBuffer, x: 0, y: 0)
        let bottomRight = readPixel(program.pixelBuffer, x: 3, y: 3)
        #expect(topLeft.blue > 250)
        #expect(topLeft.red < 5)
        #expect(bottomRight.red > 250)
        #expect(bottomRight.blue < 5)
    }

    @Test("blinds midway reveal the leading rows of every band in parallel")
    func blindsMidwayRevealBandsInParallel() throws {
        let renderer = makeRenderer()
        // 16 rows over the shader's 8 bands: each band is 2 rows tall, its
        // first (screen-upper) row revealed at half progress, its second
        // not yet.
        let format = ProgramFormat(width: 4, height: 16, frameRate: 30)
        let cameraA = InputID(rawValue: "cameraA")
        let cameraB = InputID(rawValue: "cameraB")
        let outgoing = Shot(layers: [Layer(input: cameraA)], background: .black)
        let incoming = Shot(layers: [Layer(input: cameraB)], background: .black)
        let frames = [
            cameraA: solidFrame(red: 255, green: 0, blue: 0),
            cameraB: solidFrame(red: 0, green: 0, blue: 255),
        ]

        let program = try #require(
            renderer.renderShader(
                from: outgoing,
                to: incoming,
                shader: .blinds,
                progress: 0.5,
                frames: frames,
                format: format,
                time: .zero
            )
        )

        // Two bands sampled: each opens from its screen-upper row — the
        // parallel reveal that distinguishes blinds from one full-height
        // wipe.
        for bandStart in [0, 8] {
            let upper = readPixel(program.pixelBuffer, x: 2, y: bandStart)
            let lower = readPixel(program.pixelBuffer, x: 2, y: bandStart + 1)
            #expect(upper.blue > 250)
            #expect(upper.red < 5)
            #expect(lower.red > 250)
            #expect(lower.blue < 5)
        }
    }

    @Test("the program frame stamped by a shader transition carries the tick's time and BT.709 tags")
    func shaderStampsTickTimeAndTags() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)

        let program = try #require(
            renderer.renderShader(
                from: Shot(),
                to: Shot(),
                shader: .iris,
                progress: 0.5,
                frames: [:],
                format: format,
                time: CMTime(value: 9, timescale: 30)
            )
        )

        #expect(program.presentationTime == CMTime(value: 9, timescale: 30))
        // No untagged buffer leaves the renderer (ARCHITECTURE.md, "Color
        // and pixel format conventions") — the shader path shares the
        // tagged output tail with every other render.
        let primaries = CVBufferCopyAttachment(program.pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
        #expect(primaries as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    }

    @Test("the program frame stamped by a wipe carries the tick's time and BT.709 tags")
    func wipeStampsTickTimeAndTags() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)

        let program = try #require(
            renderer.renderWipe(
                from: Shot(),
                to: Shot(),
                edge: .bottom,
                progress: 0.5,
                frames: [:],
                format: format,
                time: CMTime(value: 9, timescale: 30)
            )
        )

        #expect(program.presentationTime == CMTime(value: 9, timescale: 30))
        // No untagged buffer leaves the renderer (ARCHITECTURE.md, "Color
        // and pixel format conventions") — the wipe path shares the tagged
        // output tail with every other render.
        let primaries = CVBufferCopyAttachment(program.pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
        #expect(primaries as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
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

    // MARK: Per-layer video effect chains

    @Test("a layer's effect chain is applied to its image before placement")
    func layerChainAppliesBeforePlacement() throws {
        // A resolver whose one effect forces every pixel green, so the
        // chain's application is unmistakable in the output.
        let renderer = CoreImageShotRenderer(
            context: CIContext(options: [.useSoftwareRenderer: true]),
            makeVideoEffect: { _ in ForcedColorEffect(color: CIColor(red: 0, green: 1, blue: 0)) }
        )
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let shot = Shot(
            layers: [
                Layer(input: camera, effects: [EffectConfiguration(effect: EffectID(rawValue: "force"))])
            ]
        )

        let program = try #require(
            renderer.render(
                shot: shot,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: .zero
            )
        )

        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.green > 200)
        #expect(pixel.red < 60)
    }

    @Test("effects apply in signal order — the chain is its array")
    func layerChainAppliesInSignalOrder() throws {
        // Green then blue: the last effect in the array wins, proving the
        // chain runs front to back.
        let colors = [CIColor(red: 0, green: 1, blue: 0), CIColor(red: 0, green: 0, blue: 1)]
        // The factory is `@Sendable`, so the "which color next" counter is
        // locked rather than a captured var.
        let next = Mutex(0)
        let renderer = CoreImageShotRenderer(
            context: CIContext(options: [.useSoftwareRenderer: true]),
            makeVideoEffect: { _ in
                let index = next.withLock { value -> Int in
                    defer { value += 1 }
                    return value
                }
                return ForcedColorEffect(color: colors[min(index, colors.count - 1)])
            }
        )
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let shot = Shot(
            layers: [
                Layer(
                    input: camera,
                    effects: [
                        EffectConfiguration(effect: EffectID(rawValue: "first")),
                        EffectConfiguration(effect: EffectID(rawValue: "second")),
                    ]
                )
            ]
        )

        let program = try #require(
            renderer.render(
                shot: shot,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: .zero
            )
        )

        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.blue > 200)
        #expect(pixel.green < 60)
    }

    @Test("a chain entry with no resolvable provider renders as pass-through, never a lost layer")
    func unresolvedChainEntryPassesThrough() throws {
        let renderer = CoreImageShotRenderer(
            context: CIContext(options: [.useSoftwareRenderer: true]),
            makeVideoEffect: { _ in nil }
        )
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let shot = Shot(
            layers: [
                Layer(input: camera, effects: [EffectConfiguration(effect: EffectID(rawValue: "missing"))])
            ]
        )

        let program = try #require(
            renderer.render(
                shot: shot,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: .zero
            )
        )

        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.red > 200)
    }

    @Test("a renderer with no effect resolver renders a chained layer unchanged")
    func rendererWithoutResolverIgnoresChains() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let shot = Shot(
            layers: [
                Layer(input: camera, effects: [EffectConfiguration(effect: EffectID(rawValue: "colorAdjust"))])
            ]
        )

        let program = try #require(
            renderer.render(
                shot: shot,
                frames: [camera: solidFrame(red: 255, green: 0, blue: 0)],
                format: format,
                time: .zero
            )
        )

        let pixel = readPixel(program.pixelBuffer, x: 2, y: 2)
        #expect(pixel.red > 200)
    }

    @Test("editing a layer's chain rebuilds it, so the next tick renders the edit")
    func editingChainRebuildsIt() throws {
        let colors = [CIColor(red: 0, green: 1, blue: 0), CIColor(red: 0, green: 0, blue: 1)]
        // The factory is `@Sendable`, so the "which color next" counter is
        // locked rather than a captured var.
        let next = Mutex(0)
        let renderer = CoreImageShotRenderer(
            context: CIContext(options: [.useSoftwareRenderer: true]),
            makeVideoEffect: { _ in
                let index = next.withLock { value -> Int in
                    defer { value += 1 }
                    return value
                }
                return ForcedColorEffect(color: colors[min(index, colors.count - 1)])
            }
        )
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let camera = InputID(rawValue: "camera")
        let shotID = ShotID(rawValue: "shot")
        let frames = [camera: solidFrame(red: 255, green: 0, blue: 0)]

        let green = Shot(
            id: shotID,
            layers: [Layer(input: camera, effects: [EffectConfiguration(effect: EffectID(rawValue: "a"))])]
        )
        let first = try #require(renderer.render(shot: green, frames: frames, format: format, time: .zero))
        #expect(readPixel(first.pixelBuffer, x: 2, y: 2).green > 200)

        // Re-rendering the same shot reuses the cached instance (still green).
        let cached = try #require(renderer.render(shot: green, frames: frames, format: format, time: .zero))
        #expect(readPixel(cached.pixelBuffer, x: 2, y: 2).green > 200)

        // A changed configuration rebuilds the chain — now the blue effect.
        let edited = Shot(
            id: shotID,
            layers: [
                Layer(
                    input: camera,
                    effects: [
                        EffectConfiguration(
                            effect: EffectID(rawValue: "a"), parameters: ["amount": .double(1)])
                    ]
                )
            ]
        )
        let after = try #require(renderer.render(shot: edited, frames: frames, format: format, time: .zero))
        #expect(readPixel(after.pixelBuffer, x: 2, y: 2).blue > 200)
    }

    // MARK: - Fade to black

    @Test("the fade stage at 0 leaves the frame it was handed unchanged")
    func fadeAtZeroLeavesTheFrameUnchanged() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let frame = solidFrame(red: 200, green: 100, blue: 50)

        let faded = try #require(renderer.renderFaded(frame, toBlack: 0, format: format, time: .zero))

        #expect(readPixel(faded.pixelBuffer, x: 2, y: 2) == Pixel(blue: 50, green: 100, red: 200, alpha: 255))
    }

    @Test("the fade stage at 1 renders black, whatever it was handed")
    func fadeAtOneRendersBlack() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let frame = solidFrame(red: 200, green: 100, blue: 50)

        let faded = try #require(renderer.renderFaded(frame, toBlack: 1, format: format, time: .zero))

        #expect(readPixel(faded.pixelBuffer, x: 2, y: 2) == Pixel(blue: 0, green: 0, red: 0, alpha: 255))
    }

    @Test("the fade stage midway darkens every channel, and darkens them in order")
    func fadeMidwayDarkensEveryChannel() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let frame = solidFrame(red: 200, green: 100, blue: 50)

        let faded = try #require(renderer.renderFaded(frame, toBlack: 0.5, format: format, time: .zero))

        // Every channel darkens, none reaches black, and their order is
        // preserved — a fade dims the picture rather than tinting it. The
        // exact values are not halves of the byte values: Core Image blends
        // in its own linear working space, which the dissolve below is
        // pinned against.
        let pixel = readPixel(faded.pixelBuffer, x: 2, y: 2)
        #expect((1..<200).contains(Int(pixel.red)))
        #expect((1..<100).contains(Int(pixel.green)))
        #expect((1..<50).contains(Int(pixel.blue)))
        #expect(pixel.red > pixel.green && pixel.green > pixel.blue)
        // The program frame stays opaque — a fade darkens, never punches a hole.
        #expect(pixel.alpha == 255)
    }

    @Test("the fade stage tracks a dissolve toward black at the same progress")
    func fadeTracksADissolveTowardBlack() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let input = InputID(rawValue: "camera")
        let frames = [input: solidFrame(red: 200, green: 100, blue: 50)]
        let shot = Shot(name: "Full frame", layers: [Layer(input: input)])

        // The picture the fade is handed, and the same picture dissolved
        // toward an empty shot over opaque black.
        let composited = try #require(renderer.render(shot: shot, frames: frames, format: format, time: .zero))
        let faded = try #require(renderer.renderFaded(composited, toBlack: 0.5, format: format, time: .zero))
        let dissolved = try #require(
            renderer.renderDissolve(
                from: shot, to: Shot(), progress: 0.5, frames: frames, format: format, time: .zero)
        )

        // Fade to black and a dissolve toward black share the renderer's
        // alpha math, so the operator sees the same ramp character from
        // both — the reason the fade reuses the dissolve's convention
        // rather than inventing a second one.
        //
        // They track rather than match exactly, and the gap is inherent to
        // the master stage rather than a defect: the fade darkens the
        // *already-composited, BT.709-tagged* program frame, where the
        // dissolve blends the source images in one pass, so the fade's
        // input has been through one more encode/decode of the pipeline's
        // 8-bit working format. A handful of code values at the midpoint,
        // and none at either endpoint.
        let fadedPixel = readPixel(faded.pixelBuffer, x: 2, y: 2)
        let dissolvedPixel = readPixel(dissolved.pixelBuffer, x: 2, y: 2)
        #expect(abs(Int(fadedPixel.red) - Int(dissolvedPixel.red)) <= 10)
        #expect(abs(Int(fadedPixel.green) - Int(dissolvedPixel.green)) <= 10)
        #expect(abs(Int(fadedPixel.blue) - Int(dissolvedPixel.blue)) <= 10)
    }

    @Test("the faded frame carries the tick's time and the BT.709 tags every buffer must")
    func fadedFrameIsStampedAndTagged() throws {
        let renderer = makeRenderer()
        let format = ProgramFormat(width: 4, height: 4, frameRate: 30)
        let time = CMTime(value: 7, timescale: 30)

        let faded = try #require(
            renderer.renderFaded(solidFrame(red: 10, green: 20, blue: 30), toBlack: 0.5, format: format, time: time)
        )

        #expect(faded.presentationTime == time)
        let primaries = CVBufferCopyAttachment(faded.pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
        #expect(primaries as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    }
}

/// A test video effect that replaces the image with a flat color, so a
/// chain's application and ordering are unmistakable in the output pixels.
private struct ForcedColorEffect: VideoEffect {
    /// The color every pixel becomes.
    let color: CIColor

    /// Ignores every payload.
    func setParameters(_ parameters: [String: JSONValue]) {}

    /// Returns a flat color image over the input's extent.
    func process(_ image: CIImage) -> CIImage {
        CIImage(color: color).cropped(to: image.extent)
    }
}
