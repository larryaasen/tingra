//
//  MonitorOverlayLineup.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// The monitor overlays one monitor draws, in drawing order, with what
/// the monitor tells them about itself (ARCHITECTURE.md, "Monitor
/// overlays"). `MonitorView` applies it after fitting the picture.
///
/// Equatable by what it draws: the ids, their values, the monitor and
/// tally, and whose levels it meters. That is the half of a monitor's
/// draw-skip state the picture source cannot know, so turning an overlay on
/// redraws a still; the levels themselves are read each draw
/// (``audioLevels()``) and compared beside it.
struct MonitorOverlayLineup: Equatable {
    /// One overlay the monitor draws.
    struct Entry {
        /// The overlay's provider: its id, and whether it is available on
        /// the canvas being drawn.
        let provider: any MonitorOverlayProvider

        /// The overlay, made with ``parameters``.
        let overlay: any MonitorOverlay

        /// The values the overlay was made with.
        let parameters: [String: JSONValue]
    }

    /// The overlays, in drawing order.
    let entries: [Entry]

    /// Which monitor draws them.
    let monitor: MonitorOverlayContext.Monitor

    /// The monitor's tally.
    let tally: MonitorOverlayContext.Tally

    /// Where the monitor's audio levels come from, or nil for a monitor
    /// with no sound of its own.
    var meters: MonitorOverlayMeters?

    /// A lineup that draws nothing.
    static let none = MonitorOverlayLineup(entries: [], monitor: .program, tally: .unlit)

    /// Whether any overlay drawn asks for the monitor's audio levels.
    var usesAudioLevels: Bool {
        entries.contains { $0.provider.usesAudioLevels }
    }

    /// The monitor's audio levels now, read only while an overlay asks for
    /// them, so a monitor without meters never redraws for its sound.
    ///
    /// - Returns: One level per channel, or none.
    func audioLevels() -> [MonitorOverlayContext.AudioLevel] {
        guard usesAudioLevels, let meters else { return [] }
        return meters.levels()
    }

    /// Whether there is anything to draw.
    var isEmpty: Bool { entries.isEmpty }

    /// The ids drawn, in order.
    var ids: [MonitorOverlayID] { entries.map(\.provider.id) }

    /// Applies every overlay available on the monitor and the canvas, in
    /// order, each to the image the one before it returned.
    ///
    /// - Parameters:
    ///   - picture: The fitted picture, transparent outside its rectangle
    ///     and wherever the frame is.
    ///   - canvasSize: The frame's size before fitting.
    ///   - pictureRect: The fitted picture's rectangle in the drawable.
    ///   - drawableRect: The whole drawable.
    ///   - backingScale: Drawable pixels per point.
    ///   - audioLevels: The monitor's levels, as ``audioLevels()`` read
    ///     them for this draw (default: none).
    /// - Returns: The picture with the overlays drawn.
    func render(
        over picture: CIImage, canvasSize: CGSize, pictureRect: CGRect, drawableRect: CGRect,
        backingScale: CGFloat, audioLevels: [MonitorOverlayContext.AudioLevel] = []
    ) -> CIImage {
        guard !entries.isEmpty else { return picture }
        let context = MonitorOverlayContext(
            monitor: monitor, tally: tally, canvasSize: canvasSize, pictureRect: pictureRect,
            drawableRect: drawableRect, backingScale: backingScale, audioLevels: audioLevels)
        return entries.reduce(picture) { image, entry in
            guard entry.provider.isAvailable(on: monitor), entry.provider.isAvailable(onCanvas: canvasSize) else {
                return image
            }
            // A plug-in's overlay drawing past the drawable would leave the
            // render bigger than the texture it lands in; clip to it.
            return entry.overlay.render(over: image, in: context).cropped(to: drawableRect)
        }
    }

    /// Two lineups are equal when they draw the same overlays with the same
    /// values on the same monitor with the same tally, metering the same
    /// sound.
    static func == (lhs: MonitorOverlayLineup, rhs: MonitorOverlayLineup) -> Bool {
        lhs.monitor == rhs.monitor && lhs.tally == rhs.tally && lhs.ids == rhs.ids
            && lhs.entries.map(\.parameters) == rhs.entries.map(\.parameters) && lhs.meters == rhs.meters
    }
}
