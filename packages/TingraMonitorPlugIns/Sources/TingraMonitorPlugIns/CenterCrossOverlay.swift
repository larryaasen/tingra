//
//  CenterCrossOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// The center cross's provider: a small cross at the picture's center,
/// for framing a camera on it.
public struct CenterCrossOverlayProvider: MonitorOverlayProvider {
    /// The center cross's stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "centerCross")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "Center Cross"

    /// A guide: drawn over the picture.
    public let stage = MonitorOverlayStage.guide

    /// The cross's color.
    public var parameters: [Parameter] {
        GuideStyle.parameters
    }

    /// Creates the provider.
    public init() {}

    /// Makes one monitor's cross at the payload's settings.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        var overlay = CenterCrossOverlay()
        overlay.setParameters(parameters)
        return overlay
    }
}

/// A cross a tenth of the picture's shorter side across, at its center.
struct CenterCrossOverlay: MonitorOverlay {
    /// The cross's span as a share of the picture's shorter side.
    static let armFraction = 0.1

    /// The color and line width.
    private(set) var style = GuideStyle()

    /// Reads the color and the line width; absent or ill-shaped keys keep
    /// their values.
    mutating func setParameters(_ parameters: [String: JSONValue]) {
        style.apply(parameters)
    }

    /// Draws the cross over the picture.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        let arms = MonitorGuideGeometry.centerCross(
            in: context.pictureRect, armFraction: Self.armFraction, lineWidth: style.lineWidth(in: context))
        return GuideDrawing.fill(arms, color: style.color, over: picture)
    }
}
