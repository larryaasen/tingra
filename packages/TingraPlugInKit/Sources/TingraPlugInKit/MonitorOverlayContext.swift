//
//  MonitorOverlayContext.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics

/// What a monitor tells a ``MonitorOverlay`` about the draw it is part of
/// (PLUGINS.md, Decision 53).
///
/// Every rectangle and size here is in the monitor's **drawable pixels**,
/// in Core Image's coordinate space (origin at the bottom left), because a
/// monitor overlay is drawn after the picture is fitted to the drawable,
/// at the drawable's resolution (Decision 54). That keeps a one-pixel line
/// one pixel on any program format.
public struct MonitorOverlayContext: Sendable, Equatable {
    /// Which monitor is drawing.
    public enum Monitor: Sendable, Hashable {
        /// The program monitor: what viewers see.
        case program

        /// The preview monitor: the staged shot.
        case preview

        /// A tile showing one input.
        case input

        /// The inspector's monitor of the selected layer.
        case layer
    }

    /// Where the picture the monitor shows is, in GLOSSARY.md's tally
    /// terms: what a tally border paints.
    public enum Tally: Sendable, Hashable {
        /// Contributing to what viewers see: red.
        case program

        /// Contributing to the staged shot: green.
        case preview

        /// On neither bus: no lamp.
        case unlit
    }

    /// One audio channel's level over the latest mix block, as linear
    /// sample magnitudes from 0 (silence) to 1 (full scale).
    public struct AudioLevel: Sendable, Equatable {
        /// The largest absolute sample value in the block: the headroom
        /// signal.
        public let peak: Float

        /// The block's root-mean-square: the loudness signal.
        public let rms: Float

        /// Creates a level.
        ///
        /// - Parameters:
        ///   - peak: The largest absolute sample value, 0 to 1.
        ///   - rms: The root-mean-square, 0 to 1.
        public init(peak: Float, rms: Float) {
            self.peak = peak
            self.rms = rms
        }
    }

    /// Which monitor is drawing.
    public let monitor: Monitor

    /// The monitor's tally.
    public let tally: Tally

    /// The size, in pixels, of the frame the monitor shows before it is
    /// fitted: the program format for the program and preview monitors,
    /// the input's own size for an input tile. A crop guide's aspect is
    /// measured against it.
    public let canvasSize: CGSize

    /// Where the fitted picture sits in the drawable, in drawable pixels.
    /// A guide measures from this rectangle, never from the drawable, so
    /// it lines up with the picture whatever the monitor's shape.
    public let pictureRect: CGRect

    /// The whole drawable, in drawable pixels: what a guide may draw
    /// within. The picture is letterboxed or pillarboxed inside it.
    public let drawableRect: CGRect

    /// Drawable pixels per point: 2 on a Retina display. A guide draws a
    /// line `backingScale` pixels wide to look one point wide.
    public let backingScale: CGFloat

    /// The levels of the sound that goes with the monitor's picture, one
    /// per channel: the program mix's left and right on the program
    /// monitor, an input's own level on its input tile and on the layer
    /// monitor. Empty when the monitor has no sound, and always empty for
    /// an overlay whose provider does not ask for levels
    /// (``MonitorOverlayProvider/usesAudioLevels``), since reading them
    /// makes the monitor redraw as they change.
    public let audioLevels: [AudioLevel]

    /// Creates a context.
    ///
    /// - Parameters:
    ///   - monitor: Which monitor is drawing.
    ///   - tally: The monitor's tally.
    ///   - canvasSize: The size of the frame before fitting, in pixels.
    ///   - pictureRect: The fitted picture's rectangle in the drawable.
    ///   - drawableRect: The whole drawable.
    ///   - backingScale: Drawable pixels per point.
    public init(
        monitor: Monitor,
        tally: Tally,
        canvasSize: CGSize,
        pictureRect: CGRect,
        drawableRect: CGRect,
        backingScale: CGFloat
    ) {
        self.init(
            monitor: monitor, tally: tally, canvasSize: canvasSize, pictureRect: pictureRect,
            drawableRect: drawableRect, backingScale: backingScale, audioLevels: [])
    }

    /// Creates a context with the monitor's audio levels. A second
    /// initializer rather than a defaulted argument on the first, for the
    /// reason `PlugInContext` has two: with Library Evolution a new
    /// defaulted argument would replace the first initializer's symbol.
    ///
    /// - Parameters:
    ///   - monitor: Which monitor is drawing.
    ///   - tally: The monitor's tally.
    ///   - canvasSize: The size of the frame before fitting, in pixels.
    ///   - pictureRect: The fitted picture's rectangle in the drawable.
    ///   - drawableRect: The whole drawable.
    ///   - backingScale: Drawable pixels per point.
    ///   - audioLevels: The levels of the monitor's sound, one per channel.
    public init(
        monitor: Monitor,
        tally: Tally,
        canvasSize: CGSize,
        pictureRect: CGRect,
        drawableRect: CGRect,
        backingScale: CGFloat,
        audioLevels: [AudioLevel]
    ) {
        self.monitor = monitor
        self.tally = tally
        self.canvasSize = canvasSize
        self.pictureRect = pictureRect
        self.drawableRect = drawableRect
        self.backingScale = backingScale
        self.audioLevels = audioLevels
    }
}
