//
//  FlipHorizontalOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// Flip Horizontal's provider: the picture mirrored left to right, the way
/// a presenter facing the monitor sees their own movements, or a framing
/// checked against its mirror image. The app mirrors a monitor's layer
/// handles with it, so a drag still moves the layer the way the pointer
/// goes.
public struct FlipHorizontalOverlayProvider: MonitorOverlayProvider {
    /// Flip Horizontal's stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "flipHorizontal")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "Flip Horizontal"

    /// A picture overlay: it changes the picture itself.
    public let stage = MonitorOverlayStage.picture

    /// No settings.
    public var parameters: [Parameter] { [] }

    /// Creates the provider.
    public init() {}

    /// Makes one monitor's flip.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        FlipHorizontalOverlay()
    }
}

/// The picture mirrored about its own vertical center line, so it stays
/// where it was in the drawable.
struct FlipHorizontalOverlay: MonitorOverlay {
    /// Nothing to set.
    mutating func setParameters(_ parameters: [String: JSONValue]) {}

    /// Mirrors the picture.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        guard !context.pictureRect.isEmpty else { return picture }
        return picture.transformed(by: MonitorGuideGeometry.horizontalMirror(about: context.pictureRect.midX))
    }
}
