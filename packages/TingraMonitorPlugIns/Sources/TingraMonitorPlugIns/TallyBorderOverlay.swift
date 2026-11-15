//
//  TallyBorderOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// The tally border's provider: the monitor's tally as a border round its
/// picture, red on program and green on preview (GLOSSARY.md, "Tally"), the
/// edge the multiview's input tiles already wear. On by default (PLUGINS.md,
/// Decision 55).
public struct TallyBorderOverlayProvider: MonitorOverlayProvider {
    /// The tally border's stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "tallyBorder")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "Tally Border"

    /// A guide: drawn over the picture.
    public let stage = MonitorOverlayStage.guide

    /// The border's width. Its colors are the tally's, the same
    /// everywhere a tally is shown, so they are not settings.
    public var parameters: [Parameter] {
        [
            Parameter(
                key: TallyBorderOverlay.widthKey, name: "Width", range: TallyBorderOverlay.widthRange,
                defaultValue: Double(TallyBorderOverlay.widthPoints), unit: "pt")
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Makes one monitor's border at the payload's width.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        var overlay = TallyBorderOverlay()
        overlay.setParameters(parameters)
        return overlay
    }
}

/// A border inside the picture's edge, three points unless the project
/// says otherwise, in the tally's color; nothing for an unlit tally.
struct TallyBorderOverlay: MonitorOverlay {
    /// The border's default width in points: the width the multiview's
    /// tiles stroke their tally at.
    static let widthPoints: CGFloat = 3

    /// The persisted parameter key of the border's width.
    static let widthKey = "width"

    /// The widths accepted, in points.
    static let widthRange: ClosedRange<Double> = 1...8

    /// The border's width in points.
    private(set) var width = TallyBorderOverlay.widthPoints

    /// The program tally's red.
    static let programColor = ParameterColor(red: 1, green: 0.23, blue: 0.19)

    /// The preview tally's green.
    static let previewColor = ParameterColor(red: 0.2, green: 0.78, blue: 0.35)

    /// Reads the width, clamped to its range; an absent or ill-shaped key
    /// keeps it.
    mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let value = parameters[Self.widthKey]?.doubleValue {
            width = CGFloat(Self.widthRange.clamped(value))
        }
    }

    /// Draws the border in the tally's color.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        guard let color = Self.color(for: context.tally) else { return picture }
        let strips = MonitorGuideGeometry.outline(
            of: context.pictureRect, lineWidth: GuideDrawing.pixels(width, in: context))
        return GuideDrawing.fill(strips, color: color, over: picture)
    }

    /// The border color for a tally, or `nil` for none.
    ///
    /// - Parameter tally: The monitor's tally.
    /// - Returns: Red for program, green for preview, `nil` when unlit.
    static func color(for tally: MonitorOverlayContext.Tally) -> ParameterColor? {
        switch tally {
        case .program: programColor
        case .preview: previewColor
        case .unlit: nil
        @unknown default: nil
        }
    }
}
