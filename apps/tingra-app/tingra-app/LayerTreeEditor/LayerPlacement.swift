//
//  LayerPlacement.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import SwiftUI

/// The inspector's placement presets — a 3×3 anchor grid that moves the
/// layer and three sizes that resize it — the shape of macOS 26's window
/// tiling and of a switcher's picture-in-picture presets, so a corner is one
/// click rather than four fields (ARCHITECTURE.md, "The layer inspector").
/// Pure over normalized frames, so unit-tested with no window.
enum LayerPlacement {
    /// The gap an anchored layer keeps from the program's edges: the inset
    /// margin of the built-in picture-in-picture shot, so an inset layer
    /// anchored bottom-right lands exactly where that shot puts the camera.
    static let margin: CGFloat = ProgramLayout.insetMargin

    /// Where an anchor puts a layer — nine positions, corners and edge
    /// midpoints keeping the margin, the center centered.
    enum Anchor: String, CaseIterable, Sendable {
        case topLeading, top, topTrailing
        case leading, center, trailing
        case bottomLeading, bottom, bottomTrailing

        /// The anchor's position as a fraction of the program: `(0, 0)` is
        /// top-left, `(1, 1)` bottom-right.
        var unitPoint: CGPoint {
            switch self {
            case .topLeading: CGPoint(x: 0, y: 0)
            case .top: CGPoint(x: 0.5, y: 0)
            case .topTrailing: CGPoint(x: 1, y: 0)
            case .leading: CGPoint(x: 0, y: 0.5)
            case .center: CGPoint(x: 0.5, y: 0.5)
            case .trailing: CGPoint(x: 1, y: 0.5)
            case .bottomLeading: CGPoint(x: 0, y: 1)
            case .bottom: CGPoint(x: 0.5, y: 1)
            case .bottomTrailing: CGPoint(x: 1, y: 1)
            }
        }

        /// The SF Symbol on the anchor's button.
        var symbol: String {
            switch self {
            case .topLeading: "arrow.up.left"
            case .top: "arrow.up"
            case .topTrailing: "arrow.up.right"
            case .leading: "arrow.left"
            case .center: "scope"
            case .trailing: "arrow.right"
            case .bottomLeading: "arrow.down.left"
            case .bottom: "arrow.down"
            case .bottomTrailing: "arrow.down.right"
            }
        }

        /// The anchor's localized name, for the button's tooltip and
        /// accessibility label.
        var title: Text {
            switch self {
            case .topLeading: Text("Top Left", comment: "Layer placement anchor")
            case .top: Text("Top", comment: "Wipe edge picker option: reveal from the top edge of the frame")
            case .topTrailing: Text("Top Right", comment: "Layer placement anchor")
            case .leading: Text("Left", comment: "Wipe edge picker option: reveal from the left edge of the frame")
            case .center: Text("Center", comment: "Layer placement anchor")
            case .trailing: Text("Right", comment: "Wipe edge picker option: reveal from the right edge of the frame")
            case .bottomLeading: Text("Bottom Left", comment: "Layer placement anchor")
            case .bottom: Text("Bottom", comment: "Wipe edge picker option: reveal from the bottom edge of the frame")
            case .bottomTrailing: Text("Bottom Right", comment: "Layer placement anchor")
            }
        }

        /// The anchors in grid order, three rows of three.
        static let rows: [[Anchor]] = [
            [.topLeading, .top, .topTrailing],
            [.leading, .center, .trailing],
            [.bottomLeading, .bottom, .bottomTrailing],
        ]
    }

    /// A preset size: the whole program, half of it each way, or the inset
    /// the built-in picture-in-picture shot uses.
    enum Size: String, CaseIterable, Sendable {
        case fullFrame, half, inset

        /// The size as a fraction of the program.
        var size: CGSize {
            switch self {
            case .fullFrame: CGSize(width: 1, height: 1)
            case .half: CGSize(width: 0.5, height: 0.5)
            case .inset: ProgramLayout.cameraInsetFrame.size
            }
        }

        /// The button's localized title.
        var title: Text {
            switch self {
            case .fullFrame: Text("Full Frame", comment: "Layer placement size: the whole program")
            case .half: Text("Half", comment: "Layer placement size: half the program each way")
            case .inset: Text("Inset", comment: "Layer placement size: the picture-in-picture inset")
            }
        }
    }

    /// The frame moved to an anchor, its size kept. On each axis, a layer
    /// narrower than half the program keeps the margin from the edge it is
    /// anchored to, and a wider one sits flush — so a half-width layer
    /// anchored left *is* the left half; the center centers on that axis.
    ///
    /// - Parameters:
    ///   - frame: The layer's frame.
    ///   - anchor: Where to put it.
    /// - Returns: The anchored frame.
    static func anchoring(_ frame: CGRect, at anchor: Anchor) -> CGRect {
        let point = anchor.unitPoint
        return CGRect(
            x: position(point.x, extent: frame.width),
            y: position(point.y, extent: frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    /// The frame resized to a preset, its origin kept — except the full
    /// frame, which has only one place to be.
    ///
    /// - Parameters:
    ///   - frame: The layer's frame.
    ///   - size: The preset size.
    /// - Returns: The resized frame.
    static func sizing(_ frame: CGRect, to size: Size) -> CGRect {
        let origin = size == .fullFrame ? .zero : frame.origin
        return CGRect(origin: origin, size: size.size)
    }

    /// One axis of ``anchoring(_:at:)``: the origin that puts an extent at
    /// the near edge, the center, or the far edge, with the margin rule.
    private static func position(_ unit: CGFloat, extent: CGFloat) -> CGFloat {
        let inset = extent < 0.5 ? margin : 0
        switch unit {
        case 0: return inset
        case 1: return 1 - inset - extent
        default: return (1 - extent) / 2
        }
    }
}
