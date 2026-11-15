//
//  GuideDrawing.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// How the first-party guides draw: solid rectangles of one color
/// composited over the picture. Every guide is a handful of thin
/// rectangles, so Core Image's constant-color image cropped to each one is
/// all the drawing needed, and the result stays one lazy GPU render.
enum GuideDrawing {
    /// The parameter key every first-party guide uses for its color.
    static let colorKey = "color"

    /// The color a guide draws in unless the project says otherwise: white
    /// at 70 %, visible on any picture without hiding it.
    static let defaultColor = ParameterColor(red: 1, green: 1, blue: 1, alpha: 0.7)

    /// A guide line's width in points unless the project says otherwise;
    /// multiplied by the backing scale, so it is the same on any display.
    static let lineWidthPoints: CGFloat = 1

    /// The parameter key every first-party guide uses for its line width.
    static let lineWidthKey = "lineWidth"

    /// The line widths accepted, in points.
    static let lineWidthRange: ClosedRange<Double> = 1...4

    /// The declared color parameter every first-party guide carries.
    static var colorParameter: Parameter {
        Parameter(key: colorKey, name: "Color", defaultColor: defaultColor)
    }

    /// Fills each rectangle with the color, over the picture.
    ///
    /// - Parameters:
    ///   - rects: The rectangles to fill, in drawable pixels.
    ///   - color: The fill color.
    ///   - picture: The picture to draw over.
    /// - Returns: The picture with the rectangles drawn over it; the
    ///   picture unchanged when there is nothing to fill or the color is
    ///   fully transparent.
    static func fill(_ rects: [CGRect], color: ParameterColor, over picture: CIImage) -> CIImage {
        guard color.alpha > 0 else { return picture }
        let ink = CIImage(color: ciColor(color))
        return rects.filter { !$0.isEmpty }.reduce(picture) { image, rect in
            ink.cropped(to: rect).composited(over: image)
        }
    }

    /// The declared line width parameter every first-party guide carries.
    static var lineWidthParameter: Parameter {
        Parameter(
            key: lineWidthKey, name: "Line Width", range: lineWidthRange, defaultValue: Double(lineWidthPoints),
            unit: "pt")
    }

    /// A width in drawable pixels for a context.
    ///
    /// - Parameters:
    ///   - points: The width in points.
    ///   - context: The monitor's draw.
    /// - Returns: The width, never less than one pixel.
    static func pixels(_ points: CGFloat, in context: MonitorOverlayContext) -> CGFloat {
        max(1, (points * context.backingScale).rounded())
    }

    /// The color as Core Image's sRGB color.
    ///
    /// - Parameter color: The parameter color.
    /// - Returns: The same color for Core Image.
    static func ciColor(_ color: ParameterColor) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

/// The look every first-party guide shares and declares: its color and its
/// line width, both edited in Overlay Settings and saved per overlay with
/// the project.
struct GuideStyle: Sendable, Equatable {
    /// The declared parameters, in the order Overlay Settings shows them.
    static var parameters: [Parameter] {
        [GuideDrawing.colorParameter, GuideDrawing.lineWidthParameter]
    }

    /// The lines' color.
    private(set) var color = GuideDrawing.defaultColor

    /// The lines' width in points.
    private(set) var lineWidthPoints = GuideDrawing.lineWidthPoints

    /// Reads the color and the line width, clamped to its range; absent or
    /// ill-shaped keys keep their values.
    ///
    /// - Parameter parameters: The parameter payload.
    mutating func apply(_ parameters: [String: JSONValue]) {
        if let value = parameters[GuideDrawing.colorKey], let parsed = ParameterColor(value) {
            color = parsed
        }
        if let value = parameters[GuideDrawing.lineWidthKey]?.doubleValue {
            lineWidthPoints = CGFloat(GuideDrawing.lineWidthRange.clamped(value))
        }
    }

    /// The line width in drawable pixels for a context.
    ///
    /// - Parameter context: The monitor's draw.
    /// - Returns: The width, never less than one pixel.
    func lineWidth(in context: MonitorOverlayContext) -> CGFloat {
        GuideDrawing.pixels(lineWidthPoints, in: context)
    }
}
