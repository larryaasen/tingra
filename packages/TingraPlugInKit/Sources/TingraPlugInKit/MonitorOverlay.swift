//
//  MonitorOverlay.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage

/// Something a monitor draws over or in place of its picture for the
/// operator alone: a safe area, a crop guide, a tally border, a view for
/// checking the picture (GLOSSARY.md, "Monitor overlay"; PLUGINS.md,
/// Decisions 52–57).
///
/// A monitor overlay never reaches the program, a destination, a
/// recording, or a snapshot: the monitor applies it in its own draw, after
/// the picture is fitted to the drawable (Decision 54). The currency is
/// the effect seam's, a lazy GPU-resident `CIImage` in and out, so the
/// whole draw stays one Core Image render and an overlay needs no AppKit
/// or SwiftUI.
///
/// An instance is made by a ``MonitorOverlayProvider`` for one monitor
/// with that monitor's parameter values. The app calls it on the main
/// actor, one call at a time, at up to the display's frame rate.
public protocol MonitorOverlay: Sendable {
    /// Applies a parameter payload, keyed by the provider's declared
    /// parameter keys. Keys the payload omits keep their current values;
    /// unknown keys are ignored.
    ///
    /// - Parameter parameters: The parameter values to apply.
    mutating func setParameters(_ parameters: [String: JSONValue])

    /// Draws the overlay: returns the picture with the overlay applied,
    /// typically the picture with a few shapes composited over it (a
    /// `.guide` overlay) or a filtered picture (a `.picture` overlay). An
    /// overlay with nothing to draw for this context returns `picture`
    /// unchanged, as does one that cannot draw: a monitor overlay degrades
    /// to nothing, never to a black monitor and never to a crash.
    ///
    /// - Parameters:
    ///   - picture: What the monitor draws so far: the fitted picture,
    ///     with every earlier overlay applied. It is transparent outside
    ///     ``MonitorOverlayContext/pictureRect`` and wherever the frame
    ///     itself is (a layer's rounded corners, an image's cutout), so a
    ///     picture overlay can show that alpha; the monitor puts opaque
    ///     black under whatever the last overlay returns.
    ///   - context: The monitor, its tally, and the geometry of the draw.
    /// - Returns: The picture with this overlay applied.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage
}
