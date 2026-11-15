//
//  CenterLinesOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// The center lines' provider: a horizontal and a vertical line through the
/// picture's center, each edge to edge, for leveling a horizon or lining up
/// verticals across the frame. The center cross marks the same point
/// without covering the picture.
public struct CenterLinesOverlayProvider: MonitorOverlayProvider {
    /// The center lines' stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "centerLines")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "Center Lines"

    /// A guide: drawn over the picture.
    public let stage = MonitorOverlayStage.guide

    /// The lines' color.
    public var parameters: [Parameter] {
        GuideStyle.parameters
    }

    /// Creates the provider.
    public init() {}

    /// Makes one monitor's center lines at the payload's settings.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        var overlay = CenterLinesOverlay()
        overlay.setParameters(parameters)
        return overlay
    }
}

/// A horizontal and a vertical line through the picture's center, edge to
/// edge.
struct CenterLinesOverlay: MonitorOverlay {
    /// The color and line width.
    private(set) var style = GuideStyle()

    /// Reads the color and the line width; absent or ill-shaped keys keep
    /// their values.
    mutating func setParameters(_ parameters: [String: JSONValue]) {
        style.apply(parameters)
    }

    /// Draws the lines over the picture.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        let lines = MonitorGuideGeometry.centerLines(
            in: context.pictureRect, lineWidth: style.lineWidth(in: context))
        return GuideDrawing.fill(lines, color: style.color, over: picture)
    }
}
