//
//  VideoEffectTests.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraEffectPlugIns

/// A software Core Image context: deterministic pixel checks with no GPU
/// (the renderer tests' convention).
private let softwareContext = CIContext(options: [.useSoftwareRenderer: true])

/// A flat color image of the given size, at the origin.
private func solidImage(red: Double, green: Double, blue: Double, size: CGFloat = 16) -> CIImage {
    CIImage(color: CIColor(red: red, green: green, blue: blue))
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
}

/// Reads one pixel's RGBA bytes out of an image.
private func pixel(of image: CIImage, atX x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    var bytes = [UInt8](repeating: 0, count: 4)
    softwareContext.render(
        image,
        toBitmap: &bytes,
        rowBytes: 4,
        bounds: CGRect(x: x, y: y, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )
    return (bytes[0], bytes[1], bytes[2], bytes[3])
}

@Suite("Built-in video effects")
struct VideoEffectTests {
    @Test("a neutral color adjustment returns the image untouched")
    func neutralColorAdjustIsIdentity() {
        let effect = ColorAdjustEffect()
        let image = solidImage(red: 0.5, green: 0.5, blue: 0.5)
        #expect(effect.process(image) === image)
    }

    @Test("raising brightness lightens every channel")
    func brightnessLightens() {
        var effect = ColorAdjustEffect()
        effect.setParameters(["brightness": .double(0.3)])
        let before = pixel(of: solidImage(red: 0.4, green: 0.4, blue: 0.4), atX: 0, y: 0)
        let after = pixel(of: effect.process(solidImage(red: 0.4, green: 0.4, blue: 0.4)), atX: 0, y: 0)
        #expect(after.r > before.r)
        #expect(after.g > before.g)
        #expect(after.b > before.b)
    }

    @Test("dropping saturation to zero renders a gray of equal channels")
    func zeroSaturationIsGrayscale() {
        var effect = ColorAdjustEffect()
        effect.setParameters(["saturation": .double(0)])
        let after = pixel(of: effect.process(solidImage(red: 0.9, green: 0.2, blue: 0.2)), atX: 0, y: 0)
        #expect(after.r == after.g)
        #expect(after.g == after.b)
    }

    @Test("color adjustment payloads beyond the declared ranges are clamped")
    func colorAdjustClampsToRanges() {
        var effect = ColorAdjustEffect()
        effect.setParameters([
            "brightness": .double(50), "contrast": .double(-10), "saturation": .double(99),
        ])
        // Clamped settings still render a valid image rather than trapping
        // or producing nothing.
        let after = pixel(of: effect.process(solidImage(red: 0.5, green: 0.5, blue: 0.5)), atX: 0, y: 0)
        #expect(after.a > 0)
    }

    @Test("a blur at radius zero returns the image untouched")
    func zeroRadiusBlurIsIdentity() {
        let effect = BlurEffect()
        let image = solidImage(red: 0.5, green: 0.5, blue: 0.5)
        #expect(effect.process(image) === image)
    }

    @Test("a blur softens a hard edge into intermediate values")
    func blurSoftensAnEdge() {
        var effect = BlurEffect()
        effect.setParameters(["radiusPixels": .double(5)])
        // A black square beside a white one: the seam is hard before the
        // blur and gradated after it.
        let left = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let right = CIImage(color: .white).cropped(to: CGRect(x: 16, y: 0, width: 16, height: 16))
        let edge = right.composited(over: left)

        let sharp = pixel(of: edge, atX: 14, y: 8)
        #expect(sharp.r == 0)

        let blurred = pixel(of: effect.process(edge), atX: 14, y: 8)
        #expect(blurred.r > 0)
        #expect(blurred.r < 255)
    }

    @Test("a blur payload beyond the declared range is clamped, and the image still renders")
    func blurClampsRadius() {
        var effect = BlurEffect()
        effect.setParameters(["radiusPixels": .double(10000)])
        let after = pixel(of: effect.process(solidImage(red: 0.5, green: 0.5, blue: 0.5)), atX: 8, y: 8)
        #expect(after.a > 0)
    }

    @Test("video providers build their effect at the payload's settings")
    func providersApplyPayloadAtCreation() {
        var effect = ColorAdjustEffectProvider().makeEffect(parameters: ["saturation": .double(0)])
        let after = pixel(of: effect.process(solidImage(red: 0.9, green: 0.2, blue: 0.2)), atX: 0, y: 0)
        #expect(after.r == after.g)
        #expect(after.g == after.b)
    }
}
