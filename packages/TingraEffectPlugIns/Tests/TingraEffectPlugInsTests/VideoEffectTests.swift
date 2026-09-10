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

/// A 16×16 image, red on its left half and blue on its right.
private func halvesImage() -> CIImage {
    let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 8, y: 0, width: 8, height: 16))
    return blue.composited(over: solidImage(red: 1, green: 0, blue: 0))
}

/// A 16×16 image, green on the picture's top half (Core Image's high y)
/// and red on its bottom half.
private func topBottomImage() -> CIImage {
    let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 8, width: 16, height: 8))
    return green.composited(over: solidImage(red: 1, green: 0, blue: 0))
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

    @Test("a neutral frame returns the image untouched")
    func neutralFrameIsIdentity() {
        let effect = FrameEffect()
        let image = solidImage(red: 0.5, green: 0.5, blue: 0.5)
        #expect(effect.process(image) === image)
    }

    @Test("a frame leaves an image with an infinite extent untouched")
    func infiniteExtentPassesThrough() {
        var effect = FrameEffect()
        effect.setParameters(["cornerRadius": .double(0.5), "borderWidth": .double(0.1)])
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        #expect(effect.process(image) === image)
    }

    @Test("rounded corners make the corner pixel transparent and keep the center opaque")
    func roundedCornersClearTheCorner() {
        var effect = FrameEffect()
        effect.setParameters(["cornerRadius": .double(0.5)])
        let after = effect.process(solidImage(red: 0.2, green: 0.6, blue: 0.9, size: 32))
        #expect(after.extent == CGRect(x: 0, y: 0, width: 32, height: 32))
        #expect(pixel(of: after, atX: 0, y: 0).a == 0)
        #expect(pixel(of: after, atX: 31, y: 31).a == 0)
        let center = pixel(of: after, atX: 16, y: 16)
        #expect(center.a == 255)
        #expect(center.b > center.r)
    }

    @Test("a border paints the edge in the border color and leaves the inside alone")
    func borderPaintsTheEdge() {
        var effect = FrameEffect()
        effect.setParameters([
            "borderWidth": .double(0.1),
            "borderColor": .object(["red": .double(1), "green": .double(0), "blue": .double(0)]),
        ])
        // 40 px shorter side, so the border is 4 px wide on every edge.
        let after = effect.process(solidImage(red: 0, green: 0, blue: 1, size: 40))
        let edge = pixel(of: after, atX: 1, y: 20)
        #expect(edge.r > 200)
        #expect(edge.b < 50)
        #expect(edge.a == 255)
        let inside = pixel(of: after, atX: 20, y: 20)
        #expect(inside.b > 200)
        #expect(inside.r < 50)
        // Square corners without a radius: the corner pixel is border, not
        // transparent.
        #expect(pixel(of: after, atX: 0, y: 0).a == 255)
    }

    // MARK: Crop

    @Test("a neutral crop returns the image untouched and reports its whole extent")
    func neutralCropIsIdentity() {
        let effect = CropEffect()
        let image = solidImage(red: 0.5, green: 0.5, blue: 0.5)
        #expect(effect.process(image) === image)
        #expect(effect.outputExtent(for: image.extent) == image.extent)
    }

    @Test("a crop leaves an image with an infinite extent untouched")
    func cropInfiniteExtentPassesThrough() {
        var effect = CropEffect()
        effect.setParameters(["left": .double(0.3)])
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        #expect(effect.process(image) === image)
        #expect(effect.outputExtent(for: .infinite) == .infinite)
    }

    @Test("left and right insets keep the middle strip, and the output extent says so")
    func sideInsetsKeepTheMiddleStrip() {
        // Red on the left half, blue on the right; a quarter off each side
        // keeps a strip straddling the middle: its left pixels are still
        // red and its right pixels still blue, at their original places.
        let image = halvesImage()
        var effect = CropEffect()
        effect.setParameters(["left": .double(0.25), "right": .double(0.25)])
        let cropped = effect.process(image)
        let expected = CGRect(x: 4, y: 0, width: 8, height: 16)
        #expect(cropped.extent == expected)
        #expect(effect.outputExtent(for: image.extent) == expected)
        #expect(pixel(of: cropped, atX: 5, y: 8).r > 250)
        #expect(pixel(of: cropped, atX: 10, y: 8).b > 250)
    }

    @Test("the top inset trims the picture's top, not Core Image's bottom")
    func topInsetTrimsThePicturesTop() {
        // Green across the picture's top half (Core Image's high y), red
        // across its bottom; half off the top leaves only the red half,
        // sitting on the origin.
        let image = topBottomImage()
        var effect = CropEffect()
        effect.setParameters(["top": .double(0.5)])
        let cropped = effect.process(image)
        #expect(cropped.extent == CGRect(x: 0, y: 0, width: 16, height: 8))
        #expect(pixel(of: cropped, atX: 8, y: 4).r > 250)
        #expect(pixel(of: cropped, atX: 8, y: 4).g < 5)

        // And half off the bottom leaves only the green half, up high.
        effect.setParameters(["top": .double(0), "bottom": .double(0.5)])
        let fromBottom = effect.process(image)
        #expect(fromBottom.extent == CGRect(x: 0, y: 8, width: 16, height: 8))
        #expect(pixel(of: fromBottom, atX: 8, y: 12).g > 250)
    }

    @Test("the kept rectangle is rounded out to whole pixels")
    func cropKeepsWholePixels() {
        var effect = CropEffect()
        effect.setParameters(["left": .double(0.1), "top": .double(0.1)])
        // A tenth of 16 is 1.6: the kept rectangle rounds out to start at
        // pixel 1 and, on top, to end at pixel 15.
        let kept = effect.outputExtent(for: CGRect(x: 0, y: 0, width: 16, height: 16))
        #expect(kept == CGRect(x: 1, y: 0, width: 15, height: 15))
        #expect(kept.origin.x.rounded() == kept.origin.x)
    }

    @Test("insets beyond the declared range are clamped, and insets that meet pass the image through")
    func cropClampsAndDegradesToPassThrough() {
        var effect = CropEffect()
        effect.setParameters(["left": .double(2), "top": .double(-1)])
        // Left clamps to 0.9 (a tenth of the width remains), top to 0.
        let extent = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(effect.outputExtent(for: extent) == CGRect(x: 90, y: 0, width: 10, height: 50))

        // Left and right at the clamp together leave nothing: pass-through,
        // never a black layer.
        effect.setParameters(["right": .double(0.9)])
        let image = halvesImage()
        #expect(effect.process(image) === image)
        #expect(effect.outputExtent(for: image.extent) == image.extent)

        // An ill-shaped value keeps the current inset.
        effect.setParameters(["left": .string("half")])
        #expect(effect.outputExtent(for: extent) == extent)
    }

    @Test("a frame after a crop rounds the crop's corners, a frame before it is cropped away")
    func frameAfterCropRoundsTheCrop() {
        // The chain is signal order: a crop first hands the frame the kept
        // strip, whose own corners get rounded; a frame first rounds the
        // whole picture's corners, which the crop then cuts off.
        var crop = CropEffect()
        crop.setParameters(["left": .double(0.25), "right": .double(0.25)])
        var frame = FrameEffect()
        frame.setParameters(["cornerRadius": .double(0.25)])
        let image = solidImage(red: 1, green: 0, blue: 0)

        let cropThenFrame = frame.process(crop.process(image))
        #expect(cropThenFrame.extent == CGRect(x: 4, y: 0, width: 8, height: 16))
        // The kept strip's own corner is cleared, its center opaque.
        #expect(pixel(of: cropThenFrame, atX: 4, y: 0).a < 128)
        #expect(pixel(of: cropThenFrame, atX: 8, y: 8).a == 255)

        let frameThenCrop = crop.process(frame.process(image))
        #expect(frameThenCrop.extent == CGRect(x: 4, y: 0, width: 8, height: 16))
        // The strip's corner sits inside the whole picture's rounded
        // rectangle, so it stays opaque: the rounding was cropped away.
        #expect(pixel(of: frameThenCrop, atX: 4, y: 0).a > 200)
    }

    @Test("frame sizes beyond the declared ranges are clamped and an ill-shaped color is ignored")
    func frameClampsAndKeepsItsColor() {
        var effect = FrameEffect()
        effect.setParameters([
            "cornerRadius": .double(9), "borderWidth": .double(-3), "borderColor": .string("red"),
        ])
        // A radius clamped to a half is a full pill: the corner is clear,
        // the center is the untouched picture, and no border is drawn
        // (width clamped to zero) in the default white.
        let after = effect.process(solidImage(red: 0, green: 1, blue: 0, size: 32))
        #expect(pixel(of: after, atX: 0, y: 0).a == 0)
        let center = pixel(of: after, atX: 16, y: 16)
        #expect(center.g > 200)
        #expect(center.r < 50)
    }
}
