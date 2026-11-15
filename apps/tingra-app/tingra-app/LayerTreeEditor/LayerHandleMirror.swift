//
//  LayerHandleMirror.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics

/// How the layer handles map between a monitor and the program when the
/// monitor shows its picture mirrored by the Flip Horizontal monitor
/// overlay (PLUGINS.md, "Slice 2 as built"): every horizontal position is
/// read from the other side, and every horizontal movement runs the other
/// way, so the handles sit on the mirrored picture and a drag, a click, or
/// an arrow key still moves the layer the way the operator sees it move.
/// All in the program's normalized fractions, top-left origin; pure, so the
/// whole rule is unit-tested.
struct LayerHandleMirror: Equatable {
    /// Whether the monitor's picture is mirrored. When false, every
    /// mapping returns its input.
    let isMirrored: Bool

    /// A layer frame as the monitor draws it, or a drawn frame back to the
    /// layer's: the same mapping both ways.
    ///
    /// - Parameter frame: The frame, in program fractions.
    /// - Returns: The frame reflected about the program's center line.
    func frame(_ frame: CGRect) -> CGRect {
        guard isMirrored else { return frame }
        return CGRect(x: 1 - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// A point on the monitor as a point on the program, or back.
    ///
    /// - Parameter point: The point, in program fractions.
    /// - Returns: The point reflected about the program's center line.
    func point(_ point: CGPoint) -> CGPoint {
        CGPoint(x: x(point.x), y: point.y)
    }

    /// A horizontal position on the monitor as one on the program, or back:
    /// a snap guide's, or a handle's place along its rectangle.
    ///
    /// - Parameter x: The position, as a fraction of the width.
    /// - Returns: The position from the other side.
    func x(_ x: CGFloat) -> CGFloat {
        isMirrored ? 1 - x : x
    }

    /// A drag on the monitor as a movement of the layer.
    ///
    /// - Parameter translation: The drag, in program fractions.
    /// - Returns: The movement, its horizontal part reversed.
    func translation(_ translation: CGSize) -> CGSize {
        isMirrored ? CGSize(width: -translation.width, height: translation.height) : translation
    }

    /// An arrow key as the direction the layer moves.
    ///
    /// - Parameter direction: The arrow pressed.
    /// - Returns: The direction, left and right swapped.
    func direction(_ direction: LayerFrameGesture.NudgeDirection) -> LayerFrameGesture.NudgeDirection {
        guard isMirrored else { return direction }
        switch direction {
        case .left: return .right
        case .right: return .left
        case .up, .down: return direction
        }
    }
}
