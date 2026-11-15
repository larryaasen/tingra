//
//  RuleOfThirdsOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// The rule-of-thirds grid's provider: two lines each way dividing the
/// picture into thirds, for placing a subject on them.
public struct RuleOfThirdsOverlayProvider: MonitorOverlayProvider {
    /// The grid's stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "ruleOfThirds")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "Rule of Thirds"

    /// A guide: drawn over the picture.
    public let stage = MonitorOverlayStage.guide

    /// The grid's color.
    public var parameters: [Parameter] {
        GuideStyle.parameters
    }

    /// Creates the provider.
    public init() {}

    /// Makes one monitor's grid at the payload's settings.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        var overlay = RuleOfThirdsOverlay()
        overlay.setParameters(parameters)
        return overlay
    }
}

/// Four one-point lines at the picture's thirds.
struct RuleOfThirdsOverlay: MonitorOverlay {
    /// The color and line width.
    private(set) var style = GuideStyle()

    /// Reads the color and the line width; absent or ill-shaped keys keep
    /// their values.
    mutating func setParameters(_ parameters: [String: JSONValue]) {
        style.apply(parameters)
    }

    /// Draws the grid over the picture.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        let lines = MonitorGuideGeometry.thirds(in: context.pictureRect, lineWidth: style.lineWidth(in: context))
        return GuideDrawing.fill(lines, color: style.color, over: picture)
    }
}
