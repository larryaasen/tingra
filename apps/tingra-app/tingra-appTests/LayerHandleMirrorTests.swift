//
//  LayerHandleMirrorTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing

@testable import TingraApp

@Suite("Layer handle mirror")
struct LayerHandleMirrorTests {
    /// A mirroring mapping.
    private let mirrored = LayerHandleMirror(isMirrored: true)

    /// A mapping that changes nothing.
    private let plain = LayerHandleMirror(isMirrored: false)

    @Test("a mirrored frame is reflected about the center line, and reflecting twice gives it back")
    func frame() {
        let frame = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let reflected = mirrored.frame(frame)
        #expect(abs(reflected.minX - 0.6) < 1e-9)
        #expect(reflected.minY == 0.2)
        #expect(reflected.size == frame.size)
        let back = mirrored.frame(reflected)
        #expect(abs(back.minX - frame.minX) < 1e-9)
        #expect(plain.frame(frame) == frame)
    }

    @Test("a mirrored point and position read from the other side")
    func points() {
        #expect(mirrored.point(CGPoint(x: 0.25, y: 0.5)) == CGPoint(x: 0.75, y: 0.5))
        #expect(mirrored.x(0) == 1)
        #expect(plain.x(0.3) == 0.3)
    }

    @Test("a mirrored drag moves the layer the other way horizontally only")
    func translation() {
        #expect(mirrored.translation(CGSize(width: 0.1, height: 0.2)) == CGSize(width: -0.1, height: 0.2))
        #expect(plain.translation(CGSize(width: 0.1, height: 0.2)) == CGSize(width: 0.1, height: 0.2))
    }

    @Test("a mirrored arrow key swaps left and right and keeps up and down")
    func direction() {
        #expect(mirrored.direction(.left) == .right)
        #expect(mirrored.direction(.right) == .left)
        #expect(mirrored.direction(.up) == .up)
        #expect(mirrored.direction(.down) == .down)
        #expect(plain.direction(.left) == .left)
    }

    @Test("mappings are equal only when both mirror or both do not")
    func equality() {
        #expect(mirrored == LayerHandleMirror(isMirrored: true))
        #expect(mirrored != plain)
    }
}
