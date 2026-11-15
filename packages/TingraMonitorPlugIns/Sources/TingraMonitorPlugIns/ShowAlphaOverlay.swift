//
//  ShowAlphaOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreImage.CIFilterBuiltins
import TingraPlugInKit

/// Show Alpha's provider: the picture over a grey checkerboard, so its
/// transparent parts (an image's cutout, a layer's rounded corners) show
/// as the checkerboard instead of the monitor's black. Only the input
/// tiles and the layer monitor can show alpha: the program and preview
/// pictures are composited over black and are always opaque.
public struct ShowAlphaOverlayProvider: MonitorOverlayProvider {
    /// Show Alpha's stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "showAlpha")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "Show Alpha"

    /// A picture overlay: it changes the picture itself.
    public let stage = MonitorOverlayStage.picture

    /// No settings.
    public var parameters: [Parameter] { [] }

    /// Creates the provider.
    public init() {}

    /// Available on the input tiles and the layer monitor, whose pictures
    /// can be transparent, and not on the opaque program and preview.
    ///
    /// - Parameter monitor: The monitor asked about.
    /// - Returns: Whether the picture there can have alpha to show.
    public func isAvailable(on monitor: MonitorOverlayContext.Monitor) -> Bool {
        switch monitor {
        case .program, .preview: false
        case .input, .layer: true
        @unknown default: true
        }
    }

    /// Makes one monitor's checkerboard.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        ShowAlphaOverlay()
    }
}

/// The picture over a checkerboard of light and mid grey covering the
/// picture's rectangle.
struct ShowAlphaOverlay: MonitorOverlay {
    /// One checkerboard square's side in points; multiplied by the backing
    /// scale, so the squares look the same on any display.
    static let squarePoints: CGFloat = 8

    /// The checkerboard's lighter grey.
    static let lightGrey = CIColor(red: 0.8, green: 0.8, blue: 0.8)

    /// The checkerboard's darker grey.
    static let darkGrey = CIColor(red: 0.6, green: 0.6, blue: 0.6)

    /// Nothing to set.
    mutating func setParameters(_ parameters: [String: JSONValue]) {}

    /// Puts the picture over the checkerboard.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        guard !context.pictureRect.isEmpty else { return picture }
        let board = CIFilter.checkerboardGenerator()
        board.center = context.pictureRect.origin
        board.color0 = Self.lightGrey
        board.color1 = Self.darkGrey
        board.width = Float(Self.squarePoints * context.backingScale)
        board.sharpness = 1
        guard let checkerboard = board.outputImage?.cropped(to: context.pictureRect) else { return picture }
        return picture.composited(over: checkerboard)
    }
}
