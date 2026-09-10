//
//  LayerFrameGesture.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import TingraComposition
import TingraPlugInKit

/// One of the eight resize handles on a selected layer's frame — the
/// Keynote/Motion set: a handle at each corner and at the middle of each
/// edge (ARCHITECTURE.md, "Direct manipulation, drag-to-reorder, and undo in
/// the layer-tree editor").
enum LayerHandle: String, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Whether dragging this handle moves the frame's left edge.
    var movesLeftEdge: Bool {
        switch self {
        case .topLeft, .left, .bottomLeft: true
        default: false
        }
    }

    /// Whether dragging this handle moves the frame's right edge.
    var movesRightEdge: Bool {
        switch self {
        case .topRight, .right, .bottomRight: true
        default: false
        }
    }

    /// Whether dragging this handle moves the frame's top edge.
    var movesTopEdge: Bool {
        switch self {
        case .topLeft, .top, .topRight: true
        default: false
        }
    }

    /// Whether dragging this handle moves the frame's bottom edge.
    var movesBottomEdge: Bool {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: true
        default: false
        }
    }

    /// Whether this handle changes the width (any but the top and bottom
    /// midpoints).
    var movesHorizontally: Bool { movesLeftEdge || movesRightEdge }

    /// Whether this handle changes the height (any but the left and right
    /// midpoints).
    var movesVertically: Bool { movesTopEdge || movesBottomEdge }

    /// Where the handle sits on the frame, as a fraction of its width and
    /// height from the top-left corner: `(0, 0)` is the top-left handle,
    /// `(0.5, 1)` the bottom midpoint.
    var unitPosition: CGPoint {
        let x: CGFloat = movesLeftEdge ? 0 : movesRightEdge ? 1 : 0.5
        let y: CGFloat = movesTopEdge ? 0 : movesBottomEdge ? 1 : 0.5
        return CGPoint(x: x, y: y)
    }
}

/// The pure geometry behind manipulating a layer on the monitor — move,
/// resize, nudge, and hit-test — over the layer's **normalized,
/// top-left-origin** frame, the same space SwiftUI lays out in, so a drag
/// on the monitor maps to the model by one scale (ARCHITECTURE.md, "Direct
/// manipulation, drag-to-reorder, and undo in the layer-tree editor").
/// Pure and unit-tested with no window; ``LayerHandlesOverlay`` is the view.
enum LayerFrameGesture {
    /// The smallest a layer may be resized to on either axis, as a fraction
    /// of the program: 2%, small enough for any picture-in-picture and large
    /// enough to keep the handles apart.
    static let minimumSize: CGFloat = 0.02

    /// The distance one arrow key moves the selected layer, as a fraction of
    /// the program.
    static let nudgeStep: CGFloat = 0.01

    /// The distance a Shift-arrow moves it.
    static let largeNudgeStep: CGFloat = 0.1

    /// Which way an arrow key nudges.
    enum NudgeDirection: CaseIterable, Sendable {
        case up, down, left, right
    }

    /// The frame moved by a normalized offset. A layer may leave the canvas:
    /// a partly off-frame layer is a legitimate composition, so nothing
    /// clamps the position.
    ///
    /// - Parameters:
    ///   - frame: The frame when the drag began.
    ///   - delta: The drag's translation, normalized to the program.
    /// - Returns: The moved frame.
    static func moving(_ frame: CGRect, by delta: CGSize) -> CGRect {
        frame.offsetBy(dx: delta.width, dy: delta.height)
    }

    /// The frame resized by dragging one handle.
    ///
    /// The handle's edges follow the drag while the opposite edges hold —
    /// or, about the center, move in mirror so the center holds and the
    /// size changes by twice the drag. Holding the aspect ratio keeps the
    /// frame's original proportion: an edge handle drives its own axis and
    /// the other follows; a corner follows whichever axis the drag changed
    /// more. Neither dimension goes below ``minimumSize``.
    ///
    /// - Parameters:
    ///   - frame: The frame when the drag began.
    ///   - handle: The handle being dragged.
    ///   - delta: The drag's translation, normalized to the program.
    ///   - holdingAspect: Whether Shift is held.
    ///   - aboutCenter: Whether Option is held.
    /// - Returns: The resized frame.
    static func resizing(
        _ frame: CGRect,
        handle: LayerHandle,
        by delta: CGSize,
        holdingAspect: Bool,
        aboutCenter: Bool
    ) -> CGRect {
        let factor: CGFloat = aboutCenter ? 2 : 1
        var width = frame.width
        var height = frame.height
        if handle.movesLeftEdge { width -= delta.width * factor }
        if handle.movesRightEdge { width += delta.width * factor }
        if handle.movesTopEdge { height -= delta.height * factor }
        if handle.movesBottomEdge { height += delta.height * factor }
        width = max(width, minimumSize)
        height = max(height, minimumSize)

        if holdingAspect, frame.width > 0, frame.height > 0 {
            let aspect = frame.width / frame.height
            let widthChange = abs(width - frame.width)
            let heightChange = abs(height - frame.height) * aspect
            let widthLeads =
                handle.movesHorizontally && (!handle.movesVertically || widthChange >= heightChange)
            if widthLeads {
                height = width / aspect
            } else {
                width = height * aspect
            }
            // The clamp above can be undone by following the other axis, so
            // it applies once more — on a frame this small the aspect is
            // the lesser concern.
            width = max(width, minimumSize)
            height = max(height, minimumSize)
        }

        // The anchor: the opposite edge holds, the center holds about the
        // center, and an axis the handle does not drive stays centered —
        // which is where a top or bottom handle holding the aspect puts the
        // width it changes.
        let x: CGFloat =
            if aboutCenter {
                frame.midX - width / 2
            } else if handle.movesLeftEdge {
                frame.maxX - width
            } else if handle.movesRightEdge {
                frame.minX
            } else {
                frame.midX - width / 2
            }
        let y: CGFloat =
            if aboutCenter {
                frame.midY - height / 2
            } else if handle.movesTopEdge {
                frame.maxY - height
            } else if handle.movesBottomEdge {
                frame.minY
            } else {
                frame.midY - height / 2
            }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The frame with a new width typed into the inspector: the origin
    /// holds, the width takes the value (never below ``minimumSize``), and
    /// under the aspect lock the height follows in the frame's current
    /// proportion — the rule a Shift-drag of the right handle applies.
    ///
    /// - Parameters:
    ///   - width: The new normalized width.
    ///   - frame: The frame before the edit.
    ///   - holdingAspect: Whether the aspect lock is on.
    /// - Returns: The resized frame.
    static func settingWidth(_ width: CGFloat, of frame: CGRect, holdingAspect: Bool) -> CGRect {
        var resized = frame
        resized.size.width = max(width, minimumSize)
        if holdingAspect, frame.width > 0 {
            resized.size.height = max(resized.size.width * frame.height / frame.width, minimumSize)
        }
        return resized
    }

    /// The frame with a new height typed into the inspector — the mirror of
    /// ``settingWidth(_:of:holdingAspect:)``.
    ///
    /// - Parameters:
    ///   - height: The new normalized height.
    ///   - frame: The frame before the edit.
    ///   - holdingAspect: Whether the aspect lock is on.
    /// - Returns: The resized frame.
    static func settingHeight(_ height: CGFloat, of frame: CGRect, holdingAspect: Bool) -> CGRect {
        var resized = frame
        resized.size.height = max(height, minimumSize)
        if holdingAspect, frame.height > 0 {
            resized.size.width = max(resized.size.height * frame.width / frame.height, minimumSize)
        }
        return resized
    }

    /// The frame with its height set so the layer shows its input in the
    /// input's own proportion — the way back after an accidental stretch.
    /// The width and origin hold; only the height moves. Both aspects are
    /// width over height in pixels: a 16:9 input in a 16:9 program keeps the
    /// normalized proportion 1:1, a 16:10 display in that program is taller.
    ///
    /// - Parameters:
    ///   - frame: The frame before the edit.
    ///   - inputAspect: The input's frame width over height, in pixels.
    ///   - programAspect: The program's width over height, in pixels.
    /// - Returns: The corrected frame, or the frame unchanged when either
    ///   aspect is not positive.
    static func matchingAspect(_ frame: CGRect, inputAspect: CGFloat, programAspect: CGFloat) -> CGRect {
        guard inputAspect > 0, programAspect > 0 else { return frame }
        var matched = frame
        matched.size.height = max(frame.width * programAspect / inputAspect, minimumSize)
        return matched
    }

    /// The extent of a layer's picture after its effect chain — the
    /// input's extent handed through each effect's declared output extent
    /// in signal order — so Match Input measures the picture the layer
    /// actually shows, a crop included, without rendering it
    /// (ARCHITECTURE.md, "The Crop effect"). The renderer clips growth to
    /// the input's extent, so the walk does too.
    ///
    /// - Parameters:
    ///   - extent: The input's frame extent, in pixels.
    ///   - effects: The chain's live effects, in signal order.
    /// - Returns: The extent the chain leaves.
    static func pictureExtent(_ extent: CGRect, through effects: [any VideoEffect]) -> CGRect {
        effects.reduce(extent) { current, effect in
            effect.outputExtent(for: current).intersection(extent)
        }
    }

    /// The frame nudged one step in a direction.
    ///
    /// - Parameters:
    ///   - frame: The frame before the key press.
    ///   - direction: The arrow pressed.
    ///   - step: The distance, ``nudgeStep`` or ``largeNudgeStep``.
    /// - Returns: The nudged frame.
    static func nudging(_ frame: CGRect, _ direction: NudgeDirection, by step: CGFloat) -> CGRect {
        switch direction {
        case .up: frame.offsetBy(dx: 0, dy: -step)
        case .down: frame.offsetBy(dx: 0, dy: step)
        case .left: frame.offsetBy(dx: -step, dy: 0)
        case .right: frame.offsetBy(dx: step, dy: 0)
        }
    }

    /// The layer under a point, **topmost first** — the layer the operator
    /// sees there, which is the one drawn last.
    ///
    /// - Parameters:
    ///   - point: The point, normalized to the program.
    ///   - layers: The shot's bottom-to-top stack.
    /// - Returns: The bottom-to-top index of the topmost layer whose frame
    ///   contains the point, or nil over the background.
    static func layerIndex(at point: CGPoint, in layers: [Layer]) -> Int? {
        layers.indices.reversed().first { layers[$0].frame.contains(point) }
    }
}
