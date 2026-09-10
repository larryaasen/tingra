//
//  LayerSnap.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics

/// Keynote's smart guides for a layer drag: while a moving edge or center
/// comes within a threshold of the program's edges, center, or thirds, the
/// frame snaps onto it and the guide is reported so the overlay can draw
/// the yellow line that says why (ARCHITECTURE.md, "Direct manipulation,
/// drag-to-reorder, and undo in the layer-tree editor"). Pure, over
/// normalized frames, so it is unit-tested with no window; the threshold
/// arrives already normalized per axis, since six points is a different
/// fraction of a wide monitor than of a narrow one.
enum LayerSnap {
    /// The guide positions on each axis, as fractions of the program: the
    /// two edges, the center, and the thirds — the lines a broadcast frame
    /// is composed on.
    static let guides: [CGFloat] = [0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1]

    /// A snapped frame with the guides it landed on.
    struct Result: Equatable {
        /// The frame after snapping — the input frame when nothing was
        /// within the threshold.
        var frame: CGRect

        /// The x positions of the vertical guides the frame snapped to.
        var verticalGuides: [CGFloat] = []

        /// The y positions of the horizontal guides the frame snapped to.
        var horizontalGuides: [CGFloat] = []
    }

    /// Snaps a frame being **moved**: its left, center, and right against
    /// the vertical guides, its top, middle, and bottom against the
    /// horizontal ones — the whole frame shifts by the nearest match on
    /// each axis, its size untouched.
    ///
    /// - Parameters:
    ///   - frame: The frame where the drag has put it.
    ///   - threshold: How near, per axis, counts as a match.
    /// - Returns: The snapped frame and its guides.
    static func snappingMove(_ frame: CGRect, threshold: CGSize) -> Result {
        var result = Result(frame: frame)
        if let (shift, guide) = nearest(of: [frame.minX, frame.midX, frame.maxX], within: threshold.width) {
            result.frame.origin.x += shift
            result.verticalGuides = [guide]
        }
        if let (shift, guide) = nearest(of: [frame.minY, frame.midY, frame.maxY], within: threshold.height) {
            result.frame.origin.y += shift
            result.horizontalGuides = [guide]
        }
        return result
    }

    /// Snaps a frame being **resized**: only the edges the handle moves are
    /// candidates, and a match moves that edge alone, so the opposite edge
    /// keeps holding as the resize promised.
    ///
    /// - Parameters:
    ///   - frame: The frame where the drag has put it.
    ///   - handle: The handle being dragged.
    ///   - threshold: How near, per axis, counts as a match.
    /// - Returns: The snapped frame and its guides.
    static func snappingResize(_ frame: CGRect, handle: LayerHandle, threshold: CGSize) -> Result {
        var result = Result(frame: frame)
        if handle.movesLeftEdge, let (shift, guide) = nearest(of: [frame.minX], within: threshold.width) {
            result.frame.origin.x += shift
            result.frame.size.width -= shift
            result.verticalGuides = [guide]
        } else if handle.movesRightEdge, let (shift, guide) = nearest(of: [frame.maxX], within: threshold.width) {
            result.frame.size.width += shift
            result.verticalGuides = [guide]
        }
        if handle.movesTopEdge, let (shift, guide) = nearest(of: [frame.minY], within: threshold.height) {
            result.frame.origin.y += shift
            result.frame.size.height -= shift
            result.horizontalGuides = [guide]
        } else if handle.movesBottomEdge, let (shift, guide) = nearest(of: [frame.maxY], within: threshold.height) {
            result.frame.size.height += shift
            result.horizontalGuides = [guide]
        }
        return result
    }

    /// The smallest shift that puts one of the candidates onto a guide,
    /// with that guide — or nil when none is within the threshold.
    ///
    /// - Parameters:
    ///   - candidates: The positions that may snap (an edge, a center).
    ///   - threshold: How near counts.
    /// - Returns: The shift to apply and the guide matched, or nil.
    private static func nearest(of candidates: [CGFloat], within threshold: CGFloat) -> (CGFloat, CGFloat)? {
        var best: (shift: CGFloat, guide: CGFloat)?
        for candidate in candidates {
            for guide in guides {
                let shift = guide - candidate
                guard abs(shift) <= threshold else { continue }
                if let current = best, abs(current.shift) <= abs(shift) { continue }
                best = (shift, guide)
            }
        }
        return best.map { ($0.shift, $0.guide) }
    }
}
