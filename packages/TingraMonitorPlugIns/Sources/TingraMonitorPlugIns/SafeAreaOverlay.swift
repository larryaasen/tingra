//
//  SafeAreaOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// A safe-area guide's provider: the outline of a centered rectangle
/// covering a share of the picture, inside which titles (title safe) or
/// action (action safe) stay clear of a display's edges. Registered twice,
/// at the SMPTE ST 2046-1 sizes: 90 % for title safe, 93 % for action
/// safe.
public struct SafeAreaOverlayProvider: MonitorOverlayProvider {
    /// The title-safe guide's stable identifier.
    public static let titleSafeID = MonitorOverlayID(rawValue: "titleSafe")

    /// The action-safe guide's stable identifier.
    public static let actionSafeID = MonitorOverlayID(rawValue: "actionSafe")

    /// The provider's stable identifier.
    public let id: MonitorOverlayID

    /// The user-facing name.
    public let name: String

    /// A guide: drawn over the picture.
    public let stage = MonitorOverlayStage.guide

    /// The share of each dimension the area keeps unless the project says
    /// otherwise.
    let defaultSize: Double

    /// The size, as a share of the picture shown as a percentage, then the
    /// color and line width.
    public var parameters: [Parameter] {
        [
            Parameter(
                key: SafeAreaOverlay.sizeKey, name: "Size", range: SafeAreaOverlay.sizeRange,
                defaultValue: defaultSize, unit: "%")
        ] + GuideStyle.parameters
    }

    /// The title-safe guide: 90 % of the picture.
    public static let titleSafe = SafeAreaOverlayProvider(id: titleSafeID, name: "Title Safe", defaultSize: 0.9)

    /// The action-safe guide: 93 % of the picture.
    public static let actionSafe = SafeAreaOverlayProvider(id: actionSafeID, name: "Action Safe", defaultSize: 0.93)

    /// Creates a safe-area guide.
    ///
    /// - Parameters:
    ///   - id: The guide's identifier.
    ///   - name: The guide's user-facing name.
    ///   - defaultSize: The share of each dimension the area keeps.
    init(id: MonitorOverlayID, name: String, defaultSize: Double) {
        self.id = id
        self.name = name
        self.defaultSize = defaultSize
    }

    /// Makes one monitor's guide at the payload's settings.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        var overlay = SafeAreaOverlay(size: defaultSize)
        overlay.setParameters(parameters)
        return overlay
    }
}

/// The outline of a safe area, one point wide, inside the fitted picture.
struct SafeAreaOverlay: MonitorOverlay {
    /// The persisted parameter key of the area's size.
    static let sizeKey = "size"

    /// The sizes accepted: from half the picture to all of it.
    static let sizeRange: ClosedRange<Double> = 0.5...1

    /// The share of each dimension the area keeps.
    private(set) var size: Double

    /// The color and line width.
    private(set) var style = GuideStyle()

    /// Creates the guide at a size.
    ///
    /// - Parameter size: The share of each dimension kept.
    init(size: Double) {
        self.size = Self.sizeRange.clamped(size)
    }

    /// Reads the size, clamped to its range, the color, and the line width;
    /// absent or ill-shaped keys keep their values.
    mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let value = parameters[Self.sizeKey]?.doubleValue {
            size = Self.sizeRange.clamped(value)
        }
        style.apply(parameters)
    }

    /// Draws the outline over the picture.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        let area = MonitorGuideGeometry.safeArea(in: context.pictureRect, fraction: size)
        let strips = MonitorGuideGeometry.outline(of: area, lineWidth: style.lineWidth(in: context))
        return GuideDrawing.fill(strips, color: style.color, over: picture)
    }
}
