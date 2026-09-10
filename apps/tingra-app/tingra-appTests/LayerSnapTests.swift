//
//  LayerSnapTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing

@testable import TingraApp

@Suite("LayerSnap")
struct LayerSnapTests {
    /// A threshold of two percent on each axis.
    private let threshold = CGSize(width: 0.02, height: 0.02)

    @Test("the guides are the edges, the center, and the thirds")
    func guides() {
        #expect(LayerSnap.guides == [0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1])
    }

    @Test("a move snaps the nearest edge or center onto a guide and reports it")
    func moveSnaps() {
        let frame = CGRect(x: 0.49, y: 0.1, width: 0.2, height: 0.15)
        let result = LayerSnap.snappingMove(frame, threshold: threshold)
        #expect(abs(result.frame.minX - 0.5) < 1e-9)
        #expect(abs(result.frame.width - 0.2) < 1e-9)
        #expect(result.verticalGuides == [0.5])
        // 0.1...0.25 vertically: the top, the middle, and the bottom are all
        // far from a guide, so that axis is untouched.
        #expect(abs(result.frame.minY - 0.1) < 1e-9)
        #expect(result.horizontalGuides.isEmpty)
    }

    @Test("a move snaps its center to the program's center")
    func moveSnapsCenter() {
        let frame = CGRect(x: 0.39, y: 0.41, width: 0.2, height: 0.2)
        let result = LayerSnap.snappingMove(frame, threshold: threshold)
        #expect(abs(result.frame.midX - 0.5) < 1e-9)
        #expect(abs(result.frame.midY - 0.5) < 1e-9)
        #expect(result.verticalGuides == [0.5])
        #expect(result.horizontalGuides == [0.5])
    }

    @Test("nothing within the threshold leaves the frame unchanged with no guides")
    func moveNoSnap() {
        let frame = CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.15)
        #expect(LayerSnap.snappingMove(frame, threshold: threshold) == LayerSnap.Result(frame: frame))
    }

    @Test("a resize snaps only the edge the handle moves, holding the opposite edge")
    func resizeSnapsMovingEdge() {
        let frame = CGRect(x: 0.2, y: 0.2, width: 0.79, height: 0.3)
        let result = LayerSnap.snappingResize(frame, handle: .right, threshold: threshold)
        #expect(abs(result.frame.maxX - 1) < 1e-9)
        #expect(abs(result.frame.minX - 0.2) < 1e-9)
        #expect(result.verticalGuides == [1])
        #expect(result.horizontalGuides.isEmpty)
    }

    @Test("a left-edge resize moves the origin and shrinks the width together")
    func resizeSnapsLeftEdge() {
        let frame = CGRect(x: 0.34, y: 0.2, width: 0.3, height: 0.3)
        let result = LayerSnap.snappingResize(frame, handle: .left, threshold: threshold)
        #expect(abs(result.frame.minX - 1.0 / 3.0) < 1e-9)
        #expect(abs(result.frame.maxX - 0.64) < 1e-9)
        #expect(result.verticalGuides == [1.0 / 3.0])
    }

    @Test("a resize ignores the axis its handle does not move")
    func resizeIgnoresOtherAxis() {
        let frame = CGRect(x: 0.49, y: 0.2, width: 0.2, height: 0.79)
        let result = LayerSnap.snappingResize(frame, handle: .bottom, threshold: threshold)
        #expect(abs(result.frame.minX - 0.49) < 1e-9)
        #expect(result.verticalGuides.isEmpty)
        #expect(abs(result.frame.maxY - 1) < 1e-9)
        #expect(result.horizontalGuides == [1])
    }
}
