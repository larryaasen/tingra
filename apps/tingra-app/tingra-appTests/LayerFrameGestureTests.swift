//
//  LayerFrameGestureTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreImage
import Testing
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

@Suite("LayerFrameGesture")
struct LayerFrameGestureTests {
    /// A square layer inset from the top-left, so every edge has room to
    /// move and an aspect ratio of one keeps the arithmetic readable.
    private let square = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

    /// A 2:1 layer, for the aspect-holding cases where the axes differ.
    private let wide = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)

    /// Whether two rects agree to floating-point tolerance.
    private func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
            && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test("moving offsets the frame by the delta and keeps its size")
    func moving() {
        let moved = LayerFrameGesture.moving(square, by: CGSize(width: 0.25, height: -0.05))
        #expect(same(moved, CGRect(x: 0.35, y: 0.05, width: 0.5, height: 0.5)))
    }

    @Test("moving lets a layer leave the canvas")
    func movingOffCanvas() {
        let moved = LayerFrameGesture.moving(square, by: CGSize(width: -0.3, height: 0))
        #expect(moved.minX < 0)
    }

    @Test("the right handle grows the width and holds the left edge")
    func rightHandle() {
        let resized = LayerFrameGesture.resizing(
            square, handle: .right, by: CGSize(width: 0.1, height: 0.3), holdingAspect: false, aboutCenter: false)
        #expect(same(resized, CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.5)))
    }

    @Test("the left handle moves the left edge and holds the right")
    func leftHandle() {
        let resized = LayerFrameGesture.resizing(
            square, handle: .left, by: CGSize(width: 0.1, height: 0), holdingAspect: false, aboutCenter: false)
        #expect(same(resized, CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.5)))
        #expect(abs(resized.maxX - square.maxX) < 1e-9)
    }

    @Test("the bottom handle grows the height and holds the top")
    func bottomHandle() {
        let resized = LayerFrameGesture.resizing(
            square, handle: .bottom, by: CGSize(width: 0.4, height: 0.2), holdingAspect: false, aboutCenter: false)
        #expect(same(resized, CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.7)))
    }

    @Test("a corner handle moves both of its edges")
    func cornerHandle() {
        let resized = LayerFrameGesture.resizing(
            square, handle: .topLeft, by: CGSize(width: 0.1, height: 0.2), holdingAspect: false, aboutCenter: false)
        #expect(same(resized, CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3)))
        #expect(abs(resized.maxX - square.maxX) < 1e-9)
        #expect(abs(resized.maxY - square.maxY) < 1e-9)
    }

    @Test("resizing about the center doubles the change and holds the center")
    func aboutCenter() {
        let resized = LayerFrameGesture.resizing(
            square, handle: .topLeft, by: CGSize(width: 0.1, height: 0.1), holdingAspect: false, aboutCenter: true)
        #expect(same(resized, CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        #expect(abs(resized.midX - square.midX) < 1e-9)
        #expect(abs(resized.midY - square.midY) < 1e-9)
    }

    @Test("holding the aspect at a corner follows the axis that changed more")
    func aspectCorner() {
        let resized = LayerFrameGesture.resizing(
            square, handle: .bottomRight, by: CGSize(width: 0.2, height: 0.05), holdingAspect: true,
            aboutCenter: false)
        #expect(same(resized, CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)))
    }

    @Test("holding the aspect at an edge handle drives its own axis and centers the other")
    func aspectEdge() {
        let resized = LayerFrameGesture.resizing(
            wide, handle: .right, by: CGSize(width: 0.2, height: 0), holdingAspect: true, aboutCenter: false)
        #expect(abs(resized.width - 0.6) < 1e-9)
        #expect(abs(resized.height - 0.3) < 1e-9)
        #expect(abs(resized.minX - wide.minX) < 1e-9)
        #expect(abs(resized.midY - wide.midY) < 1e-9)
    }

    @Test("holding the aspect at the top handle drives the height and centers the width")
    func aspectTop() {
        let resized = LayerFrameGesture.resizing(
            wide, handle: .top, by: CGSize(width: 0, height: -0.1), holdingAspect: true, aboutCenter: false)
        #expect(abs(resized.height - 0.3) < 1e-9)
        #expect(abs(resized.width - 0.6) < 1e-9)
        #expect(abs(resized.maxY - wide.maxY) < 1e-9)
        #expect(abs(resized.midX - wide.midX) < 1e-9)
    }

    @Test("neither dimension shrinks below the minimum size")
    func minimumSize() {
        let resized = LayerFrameGesture.resizing(
            square, handle: .right, by: CGSize(width: -1, height: 0), holdingAspect: false, aboutCenter: false)
        #expect(abs(resized.width - LayerFrameGesture.minimumSize) < 1e-9)
        #expect(abs(resized.minX - square.minX) < 1e-9)
        let collapsed = LayerFrameGesture.resizing(
            square, handle: .bottomRight, by: CGSize(width: -1, height: -1), holdingAspect: true, aboutCenter: true)
        #expect(collapsed.width >= LayerFrameGesture.minimumSize)
        #expect(collapsed.height >= LayerFrameGesture.minimumSize)
    }

    @Test("nudging moves one step in the arrow's direction")
    func nudging() {
        let step: CGFloat = 0.01
        #expect(same(LayerFrameGesture.nudging(square, .up, by: step), square.offsetBy(dx: 0, dy: -0.01)))
        #expect(same(LayerFrameGesture.nudging(square, .down, by: step), square.offsetBy(dx: 0, dy: 0.01)))
        #expect(same(LayerFrameGesture.nudging(square, .left, by: step), square.offsetBy(dx: -0.01, dy: 0)))
        #expect(same(LayerFrameGesture.nudging(square, .right, by: step), square.offsetBy(dx: 0.01, dy: 0)))
    }

    @Test("hit testing finds the topmost layer under the point, and nothing over the background")
    func hitTesting() {
        let bottom = Layer(input: InputID(rawValue: "display"))
        let top = Layer(input: InputID(rawValue: "camera"), frame: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3))
        let layers = [bottom, top]
        #expect(LayerFrameGesture.layerIndex(at: CGPoint(x: 0.7, y: 0.7), in: layers) == 1)
        #expect(LayerFrameGesture.layerIndex(at: CGPoint(x: 0.2, y: 0.2), in: layers) == 0)
        #expect(LayerFrameGesture.layerIndex(at: CGPoint(x: 1.5, y: 0.5), in: layers) == nil)
        #expect(LayerFrameGesture.layerIndex(at: CGPoint(x: 0.5, y: 0.5), in: []) == nil)
    }

    @Test("the eight handles are four corners and four edge midpoints at their unit positions")
    func handles() {
        #expect(LayerHandle.allCases.count == 8)
        #expect(LayerHandle.allCases.filter { $0.movesHorizontally && $0.movesVertically }.count == 4)
        #expect(LayerHandle.allCases.filter { $0.movesLeftEdge }.count == 3)
        #expect(LayerHandle.allCases.filter { $0.movesBottomEdge }.count == 3)
        #expect(LayerHandle.topLeft.unitPosition == CGPoint(x: 0, y: 0))
        #expect(LayerHandle.bottom.unitPosition == CGPoint(x: 0.5, y: 1))
        #expect(LayerHandle.right.unitPosition == CGPoint(x: 1, y: 0.5))
        #expect(!LayerHandle.top.movesHorizontally)
        #expect(!LayerHandle.left.movesVertically)
    }

    @Test("a typed width holds the origin, and under the lock the height follows")
    func settingWidth() {
        let free = LayerFrameGesture.settingWidth(0.8, of: wide, holdingAspect: false)
        #expect(same(free, CGRect(x: 0.2, y: 0.3, width: 0.8, height: 0.2)))
        let locked = LayerFrameGesture.settingWidth(0.8, of: wide, holdingAspect: true)
        #expect(same(locked, CGRect(x: 0.2, y: 0.3, width: 0.8, height: 0.4)))
        let tiny = LayerFrameGesture.settingWidth(0, of: wide, holdingAspect: false)
        #expect(abs(tiny.width - LayerFrameGesture.minimumSize) < 1e-9)
    }

    @Test("a typed height holds the origin, and under the lock the width follows")
    func settingHeight() {
        let free = LayerFrameGesture.settingHeight(0.4, of: wide, holdingAspect: false)
        #expect(same(free, CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)))
        let locked = LayerFrameGesture.settingHeight(0.4, of: wide, holdingAspect: true)
        #expect(same(locked, CGRect(x: 0.2, y: 0.3, width: 0.8, height: 0.4)))
    }

    @Test("matching the input's aspect sets the height from the width, keeping the origin")
    func matchingAspect() {
        // A 16:9 input in a 16:9 program: the normalized proportion is 1:1.
        let squareOnScreen = LayerFrameGesture.matchingAspect(
            CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2), inputAspect: 16.0 / 9.0, programAspect: 16.0 / 9.0)
        #expect(same(squareOnScreen, CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        // A 16:10 display in a 16:9 program is a little taller than wide, normalized.
        let display = LayerFrameGesture.matchingAspect(
            CGRect(x: 0, y: 0, width: 0.5, height: 0.5), inputAspect: 1.6, programAspect: 16.0 / 9.0)
        #expect(abs(display.height - 0.5 * (16.0 / 9.0) / 1.6) < 1e-9)
        #expect(abs(display.width - 0.5) < 1e-9)
        // An aspect that is not positive changes nothing.
        let frame = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1)
        #expect(LayerFrameGesture.matchingAspect(frame, inputAspect: 0, programAspect: 1.5) == frame)
        #expect(LayerFrameGesture.matchingAspect(frame, inputAspect: 1.5, programAspect: -1) == frame)
    }

    @Test("the picture extent walks the chain's declared extents in signal order, clipped to the input")
    func pictureExtent() {
        let input = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // No chain: the input's own extent.
        #expect(LayerFrameGesture.pictureExtent(input, through: []) == input)
        // An effect declaring nothing (the seam's default) changes nothing.
        #expect(LayerFrameGesture.pictureExtent(input, through: [ExtentEffect(extent: nil)]) == input)
        // A crop-like effect leaves what it keeps; a second one crops that.
        let portrait = CGRect(x: 656, y: 0, width: 608, height: 1080)
        let shorter = CGRect(x: 656, y: 100, width: 608, height: 880)
        #expect(
            LayerFrameGesture.pictureExtent(
                input, through: [ExtentEffect(extent: portrait), ExtentEffect(extent: shorter)]) == shorter)
        // Growth is clipped to the input, the way the renderer clips it.
        let grown = input.insetBy(dx: -20, dy: -20)
        #expect(LayerFrameGesture.pictureExtent(input, through: [ExtentEffect(extent: grown)]) == input)
    }

    @Test("following a crop trims the frame by the same fractions, keeping the kept pixels in place")
    func followingCrop() {
        // A square input shown square; a quarter cut from each side leaves
        // the middle half at the same scale, so the frame keeps its height,
        // halves its width, and starts a quarter of the old width in.
        let input = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let sides = CGRect(x: 250, y: 0, width: 500, height: 1000)
        let trimmed = LayerFrameGesture.following(square, from: input, to: sides)
        #expect(same(trimmed, CGRect(x: 0.225, y: 0.1, width: 0.25, height: 0.5)))
        // Top is the picture's top: a top inset lowers the extent's maxY in
        // bottom-left space and moves the frame's minY down in top-left space.
        let top = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let topTrimmed = LayerFrameGesture.following(square, from: input, to: top)
        #expect(same(topTrimmed, CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)))
        // A bottom inset holds the frame's top edge.
        let bottom = CGRect(x: 0, y: 200, width: 1000, height: 800)
        let bottomTrimmed = LayerFrameGesture.following(square, from: input, to: bottom)
        #expect(same(bottomTrimmed, CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4)))
    }

    @Test("following a crop keeps a stretched frame's scale on each axis, and grows back when the crop is eased")
    func followingKeepsScaleAndReverses() {
        // A 2:1 frame showing a square input is stretched twice as wide as
        // tall; a crop trims each axis at that axis's own scale.
        let input = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let kept = CGRect(x: 100, y: 100, width: 800, height: 800)
        let trimmed = LayerFrameGesture.following(wide, from: input, to: kept)
        #expect(same(trimmed, CGRect(x: 0.24, y: 0.32, width: 0.32, height: 0.16)))
        // Easing the crop back maps through the trimmed frame to the original.
        #expect(same(LayerFrameGesture.following(trimmed, from: kept, to: input), wide))
        // Cropping in two steps lands where one step would.
        let narrower = CGRect(x: 200, y: 100, width: 600, height: 800)
        let twoSteps = LayerFrameGesture.following(trimmed, from: kept, to: narrower)
        #expect(same(twoSteps, LayerFrameGesture.following(wide, from: input, to: narrower)))
    }

    @Test(
        "following leaves the frame alone when the extent did not move or is empty, and never shrinks below the minimum"
    )
    func followingEdges() {
        let input = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(LayerFrameGesture.following(square, from: input, to: input) == square)
        #expect(LayerFrameGesture.following(square, from: .zero, to: input) == square)
        #expect(LayerFrameGesture.following(square, from: input, to: .zero) == square)
        // A small frame cropped hard clamps to the minimum size, origin held.
        let small = CGRect(x: 0.5, y: 0.5, width: 0.05, height: 0.05)
        let sliver = CGRect(x: 0, y: 0, width: 192, height: 108)
        let clamped = LayerFrameGesture.following(small, from: input, to: sliver)
        #expect(clamped.width == LayerFrameGesture.minimumSize)
        #expect(clamped.height == LayerFrameGesture.minimumSize)
        #expect(abs(clamped.minX - 0.5) < 1e-9)
        #expect(abs(clamped.minY - (0.5 + 0.05 * (1080 - 108) / 1080)) < 1e-9)
    }
}

/// A video effect whose declared output extent is fixed — or, with nil,
/// the protocol's default — so the chain walk can be checked without
/// pixels.
private struct ExtentEffect: VideoEffect {
    /// The extent to declare, or nil for the seam's default.
    let extent: CGRect?

    /// Ignores every payload.
    func setParameters(_ parameters: [String: JSONValue]) {}

    /// Returns the image unchanged.
    func process(_ image: CIImage) -> CIImage { image }

    /// The fixed extent, or the input's.
    func outputExtent(for inputExtent: CGRect) -> CGRect { extent ?? inputExtent }
}
