//
//  Layer.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import TingraPlugInKit

/// One positioned element inside a shot: an input placed into a rectangle of
/// the program frame, with an opacity (GLOSSARY.md, "Layer"). Titles,
/// overlays, and per-layer effects are later additions; a step-6 layer is an
/// input reference plus its placement.
///
/// A layer names its input by ``InputID`` rather than holding the input
/// itself, so a shot is a plain value the app can build, compare, and switch
/// live — the compositor resolves the id to the latest frame that input has
/// produced at tick time.
public struct Layer: Sendable, Equatable {
    /// The input whose latest frame fills this layer. If that input has not
    /// produced a frame yet (or has stalled), the layer contributes nothing
    /// this tick and the layers beneath it show through.
    public let input: InputID

    /// Where the input's frame is drawn within the program frame, in
    /// **normalized, top-left-origin** coordinates: `(0, 0)` is the top-left
    /// corner of the program, `(1, 1)` the bottom-right. The default fills
    /// the whole program. The compositor flips this into Core Image's
    /// bottom-left space, so callers reason in the same top-left space as
    /// SwiftUI.
    public let frame: CGRect

    /// The layer's opacity, `0` (transparent) to `1` (opaque). Values
    /// outside the range are clamped by the renderer.
    public let opacity: Double

    /// Creates a layer.
    ///
    /// - Parameters:
    ///   - input: The input whose latest frame fills the layer.
    ///   - frame: The normalized, top-left-origin destination rect within
    ///     the program frame (default: the whole program).
    ///   - opacity: The layer opacity, `0`...`1` (default `1`).
    public init(input: InputID, frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), opacity: Double = 1) {
        self.input = input
        self.frame = frame
        self.opacity = opacity
    }
}
