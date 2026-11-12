//
//  TimeTextRenderer.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import TingraPlugInKit

/// Draws one line of text — a time stamp, a timer, a countdown — into
/// pooled, `IOSurface`-backed 32BGRA pixel buffers, **transparent everywhere
/// outside the text and its backing box**, so the frame layers over a
/// camera: the compositor places each layer's image over the ones beneath
/// with its alpha, exactly as it does a text file's (ARCHITECTURE.md,
/// "Color and pixel format conventions").
///
/// **A frame is drawn only when what it shows changes.** The digits of a
/// clock change once a second and the generator ticks thirty times in it,
/// so the renderer keeps the last buffer it drew and hands the same buffer
/// out, stamped with each tick's own time, until the text or its style
/// changes. That is inside the frame ownership rule (ARCHITECTURE.md,
/// "Frame ownership across the `Input` seam"): a yielded buffer is never
/// written again, so every holder of it sees a stable picture, and the
/// pool cannot recycle it while the renderer still holds it.
///
/// Confined to a single rendering task — never crosses an isolation
/// boundary, so it needs no `Sendable`.
final class TimeTextRenderer {
    /// The frame width in pixels.
    private let width: Int

    /// The frame height in pixels.
    private let height: Int

    /// The pixel buffer pool frames are drawn into: `IOSurface`-backed
    /// 32BGRA, CG-compatible for CPU drawing (acceptable for a line of
    /// text; capture inputs stay GPU-resident).
    private let pool: GeneratorPixelBufferPool

    /// What the last drawn buffer shows, and the buffer itself, kept so an
    /// unchanged picture is not drawn again.
    private var drawn: (text: String, style: TimeTextStyle, buffer: CVPixelBuffer)?

    /// Creates a renderer and its buffer pool for the given geometry.
    ///
    /// - Parameters:
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pool = GeneratorPixelBufferPool(width: width, height: height)
    }

    /// One frame showing the text in the style, stamped with the tick's
    /// master clock time.
    ///
    /// - Parameters:
    ///   - text: The line to show.
    ///   - style: Where and how to draw it.
    ///   - time: The tick's master clock time, the frame's stamp.
    /// - Returns: The frame — the previous tick's buffer when nothing it
    ///   shows has changed.
    /// - Throws: A ``GeneratorSynthesisFailure`` if a buffer or drawing
    ///   context could not be created. The caller skips the tick — a
    ///   generator problem must never take down the pipeline — and reports
    ///   the stall.
    func render(_ text: String, style: TimeTextStyle, at time: CMTime) throws(GeneratorSynthesisFailure)
        -> CapturedFrame
    {
        if let drawn, drawn.text == text, drawn.style == style {
            return CapturedFrame(pixelBuffer: drawn.buffer, presentationTime: time)
        }
        let buffer = try pool.buffer()
        try draw(text, style: style, into: buffer)
        buffer.tagBT709()
        drawn = (text, style, buffer)
        return CapturedFrame(pixelBuffer: buffer, presentationTime: time)
    }

    /// Clears the buffer to transparent and draws the backing box and the
    /// text into it.
    ///
    /// - Parameters:
    ///   - text: The line to draw.
    ///   - style: Where and how to draw it.
    ///   - buffer: The buffer to draw into.
    /// - Throws: ``GeneratorSynthesisFailure/drawingContextUnavailable`` if
    ///   Core Graphics would not create a context.
    private func draw(_ text: String, style: TimeTextStyle, into buffer: CVPixelBuffer)
        throws(GeneratorSynthesisFailure)
    {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try GeneratorPixelBuffer.makeDrawingContext(width: width, height: height, buffer: buffer)
        let frameSize = CGSize(width: width, height: height)

        // Cleared on every draw: a pool recycles buffers and guarantees
        // nothing about their contents, and here the alpha is the point —
        // whatever a recycled buffer held would show over the camera.
        context.clear(CGRect(origin: .zero, size: frameSize))

        let margin = TimeTextLayout.margin(forFrameHeight: frameSize.height)
        var fontSize = frameSize.height * style.sizeFraction
        var line = Self.makeLine(text, fontSize: fontSize, color: style.color)
        var boxSize = TimeTextLayout.boxSize(forText: CTLineGetBoundsWithOptions(line, []).size, fontSize: fontSize)

        // A line too wide for the frame is drawn smaller, never clipped:
        // a countdown that loses its last digit is wrong, a smaller one is
        // only smaller.
        let available = frameSize.width - margin * 2
        if boxSize.width > available, boxSize.width > 0, available > 0 {
            fontSize *= available / boxSize.width
            line = Self.makeLine(text, fontSize: fontSize, color: style.color)
            boxSize = TimeTextLayout.boxSize(forText: CTLineGetBoundsWithOptions(line, []).size, fontSize: fontSize)
        }

        let textBounds = CTLineGetBoundsWithOptions(line, [])
        let origin = TimeTextLayout.boxOrigin(
            boxSize: boxSize, frameSize: frameSize, margin: margin, position: style.position)
        if style.hasBacking {
            let box = CGRect(origin: origin, size: boxSize)
            let radius = min(boxSize.height, boxSize.width) * TimeTextLayout.cornerRadiusFraction
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: TimeTextLayout.backingAlpha)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        context.textPosition = CGPoint(
            x: origin.x + (boxSize.width - textBounds.width) / 2 - textBounds.minX,
            y: origin.y + (boxSize.height - textBounds.height) / 2 - textBounds.minY
        )
        CTLineDraw(line, context)
    }

    /// Lays the text out as one Core Text line in the generators' bold
    /// monospaced face, so the digits keep their columns as they change.
    ///
    /// - Parameters:
    ///   - text: The line.
    ///   - fontSize: The font size in pixels.
    ///   - color: The text's color.
    /// - Returns: The line, ready to measure and draw.
    private static func makeLine(_ text: String, fontSize: CGFloat, color: ParameterColor) -> CTLine {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, max(1, fontSize), nil)
        // A device color, in the drawing context's own space, so the
        // parameter's components land as exactly the intended bytes: the
        // working format's primaries are the color's own (``ParameterColor``),
        // and a color in another space would be matched into this one.
        let components = [CGFloat(color.red), CGFloat(color.green), CGFloat(color.blue), CGFloat(color.alpha)]
        let foreground =
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: components)
            ?? CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}

/// Where a time generator's text and its box sit in the frame, split out
/// from the renderer because it is pure geometry — sizes in, a rectangle
/// out — so each position is verifiable without drawing a frame.
///
/// Coordinates are Core Graphics': the origin is the frame's bottom left
/// corner and y grows upward.
enum TimeTextLayout {
    /// The backing box's opacity: dark enough to carry white digits over a
    /// bright picture, light enough to read as part of it.
    static let backingAlpha: CGFloat = 0.6

    /// The backing box's corner radius, as a fraction of its shorter side.
    static let cornerRadiusFraction: CGFloat = 0.2

    /// The gap kept between the box and the frame's edges, as a fraction
    /// of the frame's height — inside the title-safe area of a 16:9
    /// picture.
    static let marginFraction: CGFloat = 0.05

    /// The gap between the box and the frame's edges, in pixels.
    ///
    /// - Parameter frameHeight: The frame's height in pixels.
    /// - Returns: The margin.
    static func margin(forFrameHeight frameHeight: CGFloat) -> CGFloat {
        (frameHeight * marginFraction).rounded()
    }

    /// The backing box's size for a measured line: the text plus padding
    /// of a quarter of the font size on every side.
    ///
    /// - Parameters:
    ///   - textSize: The line's measured size.
    ///   - fontSize: The font size it was measured at.
    /// - Returns: The box's size.
    static func boxSize(forText textSize: CGSize, fontSize: CGFloat) -> CGSize {
        let padding = fontSize / 4
        return CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)
    }

    /// The box's bottom left corner for a position: against the margins at
    /// an edge or a corner, centered along any axis the position does not
    /// pin.
    ///
    /// - Parameters:
    ///   - boxSize: The box's size.
    ///   - frameSize: The frame's size.
    ///   - margin: The gap kept from the frame's edges.
    ///   - position: Where the box sits.
    /// - Returns: The box's origin, on whole pixels.
    static func boxOrigin(boxSize: CGSize, frameSize: CGSize, margin: CGFloat, position: TimeTextPosition) -> CGPoint {
        let left = margin
        let right = frameSize.width - margin - boxSize.width
        let middleX = (frameSize.width - boxSize.width) / 2
        let bottom = margin
        let top = frameSize.height - margin - boxSize.height
        let middleY = (frameSize.height - boxSize.height) / 2
        let origin: CGPoint =
            switch position {
            case .center: CGPoint(x: middleX, y: middleY)
            case .topLeft: CGPoint(x: left, y: top)
            case .top: CGPoint(x: middleX, y: top)
            case .topRight: CGPoint(x: right, y: top)
            case .bottomLeft: CGPoint(x: left, y: bottom)
            case .bottom: CGPoint(x: middleX, y: bottom)
            case .bottomRight: CGPoint(x: right, y: bottom)
            }
        return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }
}
