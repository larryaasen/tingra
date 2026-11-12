//
//  TimeTextRendererTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("TimeTextRenderer")
struct TimeTextRendererTests {
    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let width = 320

    /// A small even-dimensioned frame keeps the pixel tests fast.
    private static let height = 180

    /// A style at a position, with the other values the tests share.
    private static func style(
        _ position: TimeTextPosition = .center,
        sizeFraction: Double = 0.1,
        color: ParameterColor = .white,
        hasBacking: Bool = true
    ) -> TimeTextStyle {
        TimeTextStyle(position: position, sizeFraction: sizeFraction, color: color, hasBacking: hasBacking)
    }

    /// A renderer at the tests' geometry.
    private static func makeRenderer() -> TimeTextRenderer {
        TimeTextRenderer(width: width, height: height)
    }

    @Test("frames are IOSurface-backed 32BGRA in the working format, tagged BT.709")
    func framesAreWorkingFormat() throws {
        let frame = try Self.makeRenderer().render("12:34", style: Self.style(), at: .zero)

        let buffer = frame.pixelBuffer
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        #expect(CVPixelBufferGetWidth(buffer) == Self.width)
        #expect(CVPixelBufferGetHeight(buffer) == Self.height)
        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil)
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        #expect(primaries as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(transfer as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        #expect(matrix as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    @Test("the frame is transparent outside the text's box, so it layers over a camera")
    func frameIsTransparentOutsideTheBox() throws {
        let frame = try Self.makeRenderer().render("12:34", style: Self.style(.center), at: .zero)

        let pixels = try bgraPixels(of: frame.pixelBuffer)
        let corners = [0, Self.width - 1, Self.width * (Self.height - 1), Self.width * Self.height - 1]
        for corner in corners {
            let pixel = pixels[corner]
            #expect(pixel == BGRAPixel(blue: 0, green: 0, red: 0, alpha: 0))
        }
        // Most of the frame is clear; only the box in the middle is not.
        let clear = pixels.count { $0.alpha == 0 }
        #expect(clear > pixels.count / 2)
        #expect(clear < pixels.count)
    }

    @Test("the text is drawn in the style's color at full alpha")
    func textCarriesItsColor() throws {
        let red = ParameterColor(red: 1, green: 0, blue: 0)
        let style = Self.style(sizeFraction: 0.3, color: red)
        let frame = try Self.makeRenderer().render("88:88", style: style, at: .zero)

        // Counted before the expectations, so a miss reports two numbers
        // rather than every pixel of the frame.
        let pixels = try bgraPixels(of: frame.pixelBuffer)
        let redPixels = pixels.count { $0 == BGRAPixel(blue: 0, green: 0, red: 255, alpha: 255) }
        let whitePixels = pixels.count { $0 == BGRAPixel(blue: 255, green: 255, red: 255, alpha: 255) }
        #expect(redPixels > 0)
        #expect(whitePixels == 0)
    }

    @Test("the background box is translucent black behind the text")
    func backingIsTranslucentBlack() throws {
        let frame = try Self.makeRenderer().render("88:88", style: Self.style(hasBacking: true), at: .zero)

        let pixels = try bgraPixels(of: frame.pixelBuffer)
        // Premultiplied black at 60 %: no color, alpha of about 153.
        let backing = pixels.count { $0.red == 0 && $0.green == 0 && $0.blue == 0 && (150...156).contains($0.alpha) }
        #expect(backing > 100)
    }

    @Test("with the background off only the text itself is drawn")
    func noBackingLeavesOnlyText() throws {
        let renderer = Self.makeRenderer()
        let backed = try renderer.render("88:88", style: Self.style(hasBacking: true), at: .zero)
        let bare = try renderer.render("88:88", style: Self.style(hasBacking: false), at: .zero)

        let backedInk = try bgraPixels(of: backed.pixelBuffer).count { $0.alpha != 0 }
        let barePixels = try bgraPixels(of: bare.pixelBuffer)
        let bareInk = barePixels.count { $0.alpha != 0 }
        #expect(bareInk > 0)
        #expect(bareInk < backedInk)
        let backing = barePixels.count {
            $0.red == 0 && $0.green == 0 && $0.blue == 0 && (150...156).contains($0.alpha)
        }
        #expect(backing == 0)
    }

    @Test("each position puts the box against its own edges of the frame")
    func positionsPlaceTheBox() throws {
        let renderer = Self.makeRenderer()
        let middleX = Self.width / 2
        let middleY = Self.height / 2

        func bounds(_ position: TimeTextPosition) throws -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
            let frame = try renderer.render("12:34", style: Self.style(position), at: .zero)
            return try #require(try inkBounds(of: frame.pixelBuffer))
        }

        // Buffer rows run top to bottom, so a small y is the top edge.
        let topLeft = try bounds(.topLeft)
        #expect(topLeft.maxX < middleX && topLeft.maxY < middleY)
        let topRight = try bounds(.topRight)
        #expect(topRight.minX > middleX && topRight.maxY < middleY)
        let bottomLeft = try bounds(.bottomLeft)
        #expect(bottomLeft.maxX < middleX && bottomLeft.minY > middleY)
        let bottomRight = try bounds(.bottomRight)
        #expect(bottomRight.minX > middleX && bottomRight.minY > middleY)
        let top = try bounds(.top)
        #expect(top.minX < middleX && top.maxX > middleX && top.maxY < middleY)
        let bottom = try bounds(.bottom)
        #expect(bottom.minX < middleX && bottom.maxX > middleX && bottom.minY > middleY)
        let center = try bounds(.center)
        #expect(center.minX < middleX && center.maxX > middleX && center.minY < middleY && center.maxY > middleY)
    }

    @Test("a larger size draws a larger box")
    func sizeScalesTheBox() throws {
        let renderer = Self.makeRenderer()
        let small = try renderer.render("12:34", style: Self.style(sizeFraction: 0.05), at: .zero)
        let large = try renderer.render("12:34", style: Self.style(sizeFraction: 0.2), at: .zero)

        let smallBounds = try #require(try inkBounds(of: small.pixelBuffer))
        let largeBounds = try #require(try inkBounds(of: large.pixelBuffer))
        #expect(largeBounds.maxY - largeBounds.minY > smallBounds.maxY - smallBounds.minY)
        #expect(largeBounds.maxX - largeBounds.minX > smallBounds.maxX - smallBounds.minX)
    }

    @Test("a line too wide for the frame is drawn smaller, inside the margins, never clipped")
    func wideTextIsFittedToTheFrame() throws {
        let frame = try Self.makeRenderer().render(
            "2026-11-11 23:59:59", style: Self.style(.center, sizeFraction: 0.5), at: .zero)

        let bounds = try #require(try inkBounds(of: frame.pixelBuffer))
        let margin = Int(TimeTextLayout.margin(forFrameHeight: CGFloat(Self.height)))
        #expect(bounds.minX >= margin - 1)
        #expect(bounds.maxX <= Self.width - margin)
    }

    @Test("an unchanged picture is handed out again as the same buffer, stamped with each tick's own time")
    func unchangedPictureReusesItsBuffer() throws {
        let renderer = Self.makeRenderer()
        let first = try renderer.render("00:01", style: Self.style(), at: seconds(1))
        let second = try renderer.render("00:01", style: Self.style(), at: seconds(1.5))

        #expect(first.pixelBuffer === second.pixelBuffer)
        #expect(first.presentationTime == seconds(1))
        #expect(second.presentationTime == seconds(1.5))
    }

    @Test("new text or a new style is drawn into a new buffer, leaving the one already handed out untouched")
    func changedPictureGetsItsOwnBuffer() throws {
        let renderer = Self.makeRenderer()
        let first = try renderer.render("00:01", style: Self.style(), at: seconds(1))
        let before = try bgraPixels(of: first.pixelBuffer)

        let second = try renderer.render("00:02", style: Self.style(), at: seconds(2))
        let third = try renderer.render("00:02", style: Self.style(.topLeft), at: seconds(2.1))

        #expect(first.pixelBuffer !== second.pixelBuffer)
        #expect(second.pixelBuffer !== third.pixelBuffer)
        let firstIsUntouched = try bgraPixels(of: first.pixelBuffer) == before
        let secondDiffers = try bgraPixels(of: second.pixelBuffer) != before
        #expect(firstIsUntouched)
        #expect(secondDiffers)
    }

    @Test("a recycled buffer is cleared before it is drawn, so an earlier picture never shows through")
    func recycledBuffersAreCleared() throws {
        let renderer = Self.makeRenderer()
        // Each frame is dropped before the next is drawn, so the pool hands
        // the same buffers back: the picture moves corner to corner, and
        // only the newest box may remain.
        for index in 0..<8 {
            let position: TimeTextPosition = index.isMultiple(of: 2) ? .topLeft : .bottomRight
            let frame = try renderer.render("00:0\(index)", style: Self.style(position), at: seconds(Double(index)))
            let bounds = try #require(try inkBounds(of: frame.pixelBuffer))
            if position == .topLeft {
                #expect(bounds.maxX < Self.width / 2 && bounds.maxY < Self.height / 2)
            } else {
                #expect(bounds.minX > Self.width / 2 && bounds.minY > Self.height / 2)
            }
        }
    }
}

@Suite("TimeTextLayout")
struct TimeTextLayoutTests {
    /// The frame the geometry tests lay out in.
    private static let frame = CGSize(width: 1920, height: 1080)

    /// The box the geometry tests place.
    private static let box = CGSize(width: 400, height: 100)

    @Test("the margin is five percent of the frame's height")
    func marginFollowsFrameHeight() {
        #expect(TimeTextLayout.margin(forFrameHeight: 1080) == 54)
    }

    @Test("the box pads the text by a quarter of the font size on every side")
    func boxPadsTheText() {
        let size = TimeTextLayout.boxSize(forText: CGSize(width: 300, height: 80), fontSize: 100)
        #expect(size == CGSize(width: 350, height: 130))
    }

    @Test(
        "each position's origin sits against the margins, in bottom-left-origin coordinates",
        arguments: [
            (TimeTextPosition.center, CGPoint(x: 760, y: 490)),
            (.topLeft, CGPoint(x: 54, y: 926)),
            (.top, CGPoint(x: 760, y: 926)),
            (.topRight, CGPoint(x: 1466, y: 926)),
            (.bottomLeft, CGPoint(x: 54, y: 54)),
            (.bottom, CGPoint(x: 760, y: 54)),
            (.bottomRight, CGPoint(x: 1466, y: 54)),
        ]
    )
    func originForPosition(position: TimeTextPosition, expected: CGPoint) {
        let origin = TimeTextLayout.boxOrigin(
            boxSize: Self.box, frameSize: Self.frame, margin: 54, position: position)
        #expect(origin == expected)
    }
}

@Suite("TimeTextStyleParameters")
struct TimeTextStyleParametersTests {
    /// The parameters with a corner default, as the time stamp declares them.
    private static let parameters = TimeTextStyleParameters(defaultPosition: .bottomRight, defaultSizePercent: 5)

    @Test("the four parameters are declared in order, under the Appearance heading")
    func declaresFourParameters() {
        let all = Self.parameters.all

        #expect(all.map(\.key) == ["position", "sizePercent", "textColor", "background"])
        #expect(all.map(\.kind) == [.choice, .number, .color, .toggle])
        #expect(all.allSatisfy { $0.section == "Appearance" })
        #expect(Self.parameters.position.choices.count == TimeTextPosition.allCases.count)
        #expect(Self.parameters.size.range == 2...50)
        #expect(Self.parameters.size.unit == "%")
    }

    @Test("an empty payload reads as the declared defaults")
    func emptyPayloadReadsDefaults() {
        let style = Self.parameters.style(in: [:])

        #expect(style == TimeTextStyle(position: .bottomRight, sizeFraction: 0.05, color: .white, hasBacking: true))
    }

    @Test("a payload's values are read into the style")
    func payloadValuesAreRead() {
        let style = Self.parameters.style(in: [
            "position": .double(1),
            "sizePercent": .double(20),
            "textColor": ParameterColor(red: 1, green: 0.5, blue: 0).jsonValue,
            "background": .bool(false),
        ])

        #expect(style.position == .topLeft)
        #expect(style.sizeFraction == 0.2)
        #expect(style.color == ParameterColor(red: 1, green: 0.5, blue: 0))
        #expect(!style.hasBacking)
    }

    @Test("a size outside the range is clamped, and a position no case has reads as the default")
    func outOfRangeValuesAreTamed() {
        let style = Self.parameters.style(in: ["position": .double(99), "sizePercent": .double(900)])

        #expect(style.position == .bottomRight)
        #expect(style.sizeFraction == 0.5)
    }

    @Test("styles that differ in any part are not equal")
    func stylesCompareByValue() {
        let style = Self.parameters.style(in: [:])
        var moved = style
        moved.position = .center

        #expect(style == Self.parameters.style(in: [:]))
        #expect(style != moved)
    }

    @Test("every position has its own name and payload number")
    func positionsAreDistinct() {
        #expect(Set(TimeTextPosition.allCases.map(\.name)).count == 7)
        #expect(TimeTextPosition.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6])
    }
}
