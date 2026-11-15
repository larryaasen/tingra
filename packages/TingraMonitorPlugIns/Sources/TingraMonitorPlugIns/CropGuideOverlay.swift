//
//  CropGuideOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreImage
import TingraPlugInKit

/// A crop guide's provider: what a crop of the program to another aspect
/// ratio keeps, outlined, with the rest of the picture shaded. For a show
/// also cut down for a square or vertical feed, so the operator keeps the
/// action inside both. Registered three times: 4:3, 1:1, and 9:16.
public struct CropGuideOverlayProvider: MonitorOverlayProvider {
    /// The 4:3 guide's stable identifier.
    public static let fourByThreeID = MonitorOverlayID(rawValue: "crop4x3")

    /// The 1:1 guide's stable identifier.
    public static let squareID = MonitorOverlayID(rawValue: "crop1x1")

    /// The 9:16 guide's stable identifier.
    public static let nineBySixteenID = MonitorOverlayID(rawValue: "crop9x16")

    /// The provider's stable identifier.
    public let id: MonitorOverlayID

    /// The user-facing name.
    public let name: String

    /// A guide: drawn over the picture.
    public let stage = MonitorOverlayStage.guide

    /// The kept area's aspect ratio, width over height.
    let aspect: Double

    /// The outline's color and line width, and how dark the cropped-away
    /// area is shaded.
    public var parameters: [Parameter] {
        GuideStyle.parameters + [
            Parameter(
                key: CropGuideOverlay.shadingKey, name: "Shading", range: 0...1,
                defaultValue: CropGuideOverlay.defaultShading, unit: "%")
        ]
    }

    /// The 4:3 guide.
    public static let fourByThree = CropGuideOverlayProvider(id: fourByThreeID, name: "4:3 Crop", aspect: 4.0 / 3.0)

    /// The 1:1 guide.
    public static let square = CropGuideOverlayProvider(id: squareID, name: "1:1 Crop", aspect: 1)

    /// The 9:16 guide.
    public static let nineBySixteen = CropGuideOverlayProvider(
        id: nineBySixteenID, name: "9:16 Crop", aspect: 9.0 / 16.0)

    /// Creates a crop guide.
    ///
    /// - Parameters:
    ///   - id: The guide's identifier.
    ///   - name: The guide's user-facing name.
    ///   - aspect: The kept area's aspect, width over height.
    init(id: MonitorOverlayID, name: String, aspect: Double) {
        self.id = id
        self.name = name
        self.aspect = aspect
    }

    /// Unavailable on a canvas already of this aspect, where the crop
    /// would keep everything.
    public func isAvailable(onCanvas canvasSize: CGSize) -> Bool {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return true }
        return !MonitorGuideGeometry.aspectsMatch(canvasSize.width / canvasSize.height, aspect)
    }

    /// Makes one monitor's guide at the payload's settings.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        var overlay = CropGuideOverlay(aspect: aspect)
        overlay.setParameters(parameters)
        return overlay
    }
}

/// A crop to one aspect ratio, drawn as an outline round the kept area and
/// shading over the rest.
struct CropGuideOverlay: MonitorOverlay {
    /// The persisted parameter key of the shading's opacity.
    static let shadingKey = "shading"

    /// How dark the cropped-away area is unless the project says
    /// otherwise: enough to read as outside, not enough to hide it.
    static let defaultShading = 0.4

    /// The kept area's aspect, width over height.
    let aspect: Double

    /// The color and line width.
    private(set) var style = GuideStyle()

    /// The shading's opacity, `0...1`.
    private(set) var shading = CropGuideOverlay.defaultShading

    /// Creates the guide for an aspect.
    ///
    /// - Parameter aspect: The kept area's aspect, width over height.
    init(aspect: Double) {
        self.aspect = aspect
    }

    /// Reads the color, the line width, and the shading, clamped to
    /// `0...1`; absent or
    /// ill-shaped keys keep their values.
    mutating func setParameters(_ parameters: [String: JSONValue]) {
        style.apply(parameters)
        if let value = parameters[Self.shadingKey]?.doubleValue {
            shading = (0.0...1.0).clamped(value)
        }
    }

    /// Shades outside the kept area and outlines it; nothing when the crop
    /// would keep the whole picture.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        let kept = MonitorGuideGeometry.cropArea(in: context.pictureRect, aspect: aspect)
        let outside = MonitorGuideGeometry.bands(around: kept, in: context.pictureRect)
        guard !outside.isEmpty else { return picture }
        let shaded = GuideDrawing.fill(
            outside, color: ParameterColor(red: 0, green: 0, blue: 0, alpha: shading), over: picture)
        let strips = MonitorGuideGeometry.outline(of: kept, lineWidth: style.lineWidth(in: context))
        return GuideDrawing.fill(strips, color: style.color, over: shaded)
    }
}
