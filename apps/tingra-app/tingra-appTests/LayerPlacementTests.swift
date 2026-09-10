//
//  LayerPlacementTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing

@testable import TingraApp

@Suite("LayerPlacement")
struct LayerPlacementTests {
    /// Whether two rects agree to floating-point tolerance.
    private func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
            && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test("fitting a picture wider than the program letterboxes it, centered, at full width")
    func fittingWiderPicture() {
        let frame = LayerPlacement.fitting(inputAspect: 4, in: 16.0 / 9.0)
        #expect(frame.origin.x == 0)
        #expect(frame.width == 1)
        #expect(abs(frame.height - (16.0 / 9.0) / 4) < 0.0001)
        #expect(abs(frame.midY - 0.5) < 0.0001)
    }

    @Test("fitting a picture narrower than the program pillarboxes it, centered, at full height")
    func fittingNarrowerPicture() {
        let frame = LayerPlacement.fitting(inputAspect: 1, in: 16.0 / 9.0)
        #expect(frame.origin.y == 0)
        #expect(frame.height == 1)
        #expect(abs(frame.width - 9.0 / 16.0) < 0.0001)
        #expect(abs(frame.midX - 0.5) < 0.0001)
    }

    @Test("fitting a picture of the program's own shape, or a degenerate one, is the full frame")
    func fittingSameShapeOrDegenerate() {
        #expect(LayerPlacement.fitting(inputAspect: 16.0 / 9.0, in: 16.0 / 9.0) == LayerPlacement.fullFrame)
        #expect(LayerPlacement.fitting(inputAspect: 0, in: 16.0 / 9.0) == LayerPlacement.fullFrame)
        #expect(LayerPlacement.fitting(inputAspect: 1, in: 0) == LayerPlacement.fullFrame)
        #expect(LayerPlacement.fitting(inputAspect: .infinity, in: 1) == LayerPlacement.fullFrame)
        #expect(LayerPlacement.fullFrame == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("Inset then Bottom Right reproduces the built-in picture-in-picture camera")
    func insetBottomRightIsThePiP() {
        let anywhere = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.6)
        let inset = LayerPlacement.sizing(anywhere, to: .inset)
        let placed = LayerPlacement.anchoring(inset, at: .bottomTrailing)
        #expect(same(placed, ProgramLayout.cameraInsetFrame))
    }

    @Test("a narrow layer keeps the margin at every edge anchor and centers in the middle")
    func narrowLayerAnchors() {
        let small = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        let margin = LayerPlacement.margin
        #expect(
            same(
                LayerPlacement.anchoring(small, at: .topLeading), CGRect(x: margin, y: margin, width: 0.2, height: 0.2))
        )
        #expect(same(LayerPlacement.anchoring(small, at: .top), CGRect(x: 0.4, y: margin, width: 0.2, height: 0.2)))
        #expect(
            same(
                LayerPlacement.anchoring(small, at: .trailing), CGRect(x: 0.8 - margin, y: 0.4, width: 0.2, height: 0.2)
            ))
        #expect(same(LayerPlacement.anchoring(small, at: .center), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
        #expect(
            same(
                LayerPlacement.anchoring(small, at: .bottomLeading),
                CGRect(x: margin, y: 0.8 - margin, width: 0.2, height: 0.2)))
    }

    @Test("a half-width layer anchored left is the left half, flush")
    func halfSitsFlush() {
        let half = LayerPlacement.sizing(CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1), to: .half)
        #expect(same(half, CGRect(x: 0.3, y: 0.3, width: 0.5, height: 0.5)))
        #expect(same(LayerPlacement.anchoring(half, at: .leading), CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5)))
        #expect(
            same(LayerPlacement.anchoring(half, at: .bottomTrailing), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
    }

    @Test("the full frame is the full frame at every anchor and from any origin")
    func fullFrame() {
        let full = LayerPlacement.sizing(CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1), to: .fullFrame)
        #expect(same(full, CGRect(x: 0, y: 0, width: 1, height: 1)))
        for anchor in LayerPlacement.Anchor.allCases {
            #expect(same(LayerPlacement.anchoring(full, at: anchor), full))
        }
    }

    @Test("anchoring keeps the size and sizing keeps the origin")
    func invariants() {
        let frame = CGRect(x: 0.3, y: 0.1, width: 0.25, height: 0.4)
        for anchor in LayerPlacement.Anchor.allCases {
            #expect(LayerPlacement.anchoring(frame, at: anchor).size == frame.size)
        }
        #expect(LayerPlacement.sizing(frame, to: .inset).origin == frame.origin)
        #expect(LayerPlacement.sizing(frame, to: .half).origin == frame.origin)
    }

    @Test("the grid is nine anchors in three rows, every one distinct")
    func grid() {
        let rows = LayerPlacement.Anchor.rows
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.count == 3 })
        #expect(Set(rows.flatMap { $0 }).count == 9)
        #expect(Set(LayerPlacement.Anchor.allCases.map(\.symbol)).count == 9)
        #expect(LayerPlacement.Size.allCases.count == 3)
    }
}
