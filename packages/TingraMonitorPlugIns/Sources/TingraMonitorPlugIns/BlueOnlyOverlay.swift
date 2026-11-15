//
//  BlueOnlyOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreImage.CIFilterBuiltins
import TingraPlugInKit

/// Blue Only's provider: the picture's blue channel shown as a grey
/// picture, the classic check for setting chroma and hue against color
/// bars, where the bars' blue-only view reads as equal steps once the
/// display is set right.
public struct BlueOnlyOverlayProvider: MonitorOverlayProvider {
    /// Blue Only's stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "blueOnly")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "Blue Only"

    /// A picture overlay: it changes the picture itself.
    public let stage = MonitorOverlayStage.picture

    /// No settings.
    public var parameters: [Parameter] { [] }

    /// Creates the provider.
    public init() {}

    /// Makes one monitor's blue-only view.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        BlueOnlyOverlay()
    }
}

/// The blue channel copied into red and green, alpha kept.
struct BlueOnlyOverlay: MonitorOverlay {
    /// Nothing to set.
    mutating func setParameters(_ parameters: [String: JSONValue]) {}

    /// Shows the blue channel as grey.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        let blue = CIVector(x: 0, y: 0, z: 1, w: 0)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = picture
        filter.rVector = blue
        filter.gVector = blue
        filter.bVector = blue
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return filter.outputImage ?? picture
    }
}
