//
//  MonitorOverlayRenderTests.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreImage
import Testing
import TingraPlugInKit

@testable import TingraMonitorPlugIns

/// Renders overlays over a small black picture and reads pixels back, to
/// check each one draws where its geometry says and nowhere else.
@Suite("Monitor overlay rendering")
struct MonitorOverlayRenderTests {
    /// The drawable: 160 by 90 pixels, the picture filling it.
    private let bounds = CGRect(x: 0, y: 0, width: 160, height: 90)

    /// An opaque black picture covering the drawable.
    private var black: CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
    }

    /// A program monitor's context at one pixel per point.
    private func context(tally: MonitorOverlayContext.Tally = .program) -> MonitorOverlayContext {
        MonitorOverlayContext(
            monitor: .program, tally: tally, canvasSize: CGSize(width: 1920, height: 1080), pictureRect: bounds,
            drawableRect: bounds, backingScale: 1)
    }

    /// The RGBA bytes of one pixel of an image, origin bottom left, in
    /// sRGB, the space the overlays' colors are given in.
    ///
    /// - Parameters:
    ///   - image: The image to read.
    ///   - x: The pixel's column.
    ///   - y: The pixel's row, from the bottom.
    /// - Returns: Red, green, blue, and alpha, 0 to 255.
    private func pixel(_ image: CIImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    @Test("the title-safe outline lights its edge and leaves the center and the margin black")
    func titleSafe() {
        let overlay = SafeAreaOverlayProvider.titleSafe.makeOverlay(parameters: [
            "color": ParameterColor.white.jsonValue
        ])
        let drawn = overlay.render(over: black, in: context())
        // 90 % of 160 by 90 is inset 8 by 4.5, which snaps to 5.
        #expect(pixel(drawn, x: 8, y: 45)[0] == 255)
        #expect(pixel(drawn, x: 80, y: 45)[0] == 0)
        #expect(pixel(drawn, x: 2, y: 45)[0] == 0)
    }

    @Test("the tally border paints the picture's edge red on program")
    func tallyBorderProgram() {
        let drawn = TallyBorderOverlayProvider().makeOverlay(parameters: [:]).render(over: black, in: context())
        let edge = pixel(drawn, x: 0, y: 45)
        #expect(edge[0] > 200)
        #expect(edge[1] < 100)
        #expect(pixel(drawn, x: 80, y: 45)[0] == 0)
    }

    @Test("the tally border paints green on preview and nothing when unlit")
    func tallyBorderOtherTallies() {
        let overlay = TallyBorderOverlayProvider().makeOverlay(parameters: [:])
        let preview = pixel(overlay.render(over: black, in: context(tally: .preview)), x: 0, y: 45)
        #expect(preview[1] > 150)
        #expect(preview[0] < 100)
        let unlit = overlay.render(over: black, in: context(tally: .unlit))
        #expect(pixel(unlit, x: 0, y: 45) == [0, 0, 0, 255])
    }

    @Test("a 1:1 crop guide shades the sides and leaves its kept center untouched")
    func squareCrop() {
        let overlay = CropGuideOverlayProvider.square.makeOverlay(parameters: [
            "color": ParameterColor.white.jsonValue, "shading": .double(1),
        ])
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: bounds)
        let drawn = overlay.render(over: grey, in: context())
        // The kept square is 90 by 90, from x 35 to 125.
        #expect(pixel(drawn, x: 10, y: 45)[0] == 0)
        #expect(pixel(drawn, x: 80, y: 45)[0] > 100)
        #expect(pixel(drawn, x: 35, y: 45)[0] == 255)
    }

    @Test("the center cross lights the center and leaves a corner black")
    func centerCross() {
        let overlay = CenterCrossOverlayProvider().makeOverlay(parameters: ["color": ParameterColor.white.jsonValue])
        let drawn = overlay.render(over: black, in: context())
        #expect(pixel(drawn, x: 80, y: 45)[0] == 255)
        #expect(pixel(drawn, x: 5, y: 5)[0] == 0)
    }

    @Test("the center lines light the picture's edges on its center row and column")
    func centerLines() {
        let overlay = CenterLinesOverlayProvider().makeOverlay(parameters: ["color": ParameterColor.white.jsonValue])
        let drawn = overlay.render(over: black, in: context())
        #expect(pixel(drawn, x: 0, y: 45)[0] == 255)
        #expect(pixel(drawn, x: 159, y: 45)[0] == 255)
        #expect(pixel(drawn, x: 80, y: 0)[0] == 255)
        #expect(pixel(drawn, x: 80, y: 89)[0] == 255)
        #expect(pixel(drawn, x: 5, y: 5)[0] == 0)
    }

    @Test("the rule-of-thirds grid lights a third and leaves the center black")
    func ruleOfThirds() {
        let overlay = RuleOfThirdsOverlayProvider().makeOverlay(parameters: [
            "color": ParameterColor.white.jsonValue
        ])
        let drawn = overlay.render(over: black, in: context())
        #expect(pixel(drawn, x: 53, y: 10)[0] == 255)
        #expect(pixel(drawn, x: 80, y: 45)[0] == 0)
    }

    @Test("flip horizontal moves the picture's left edge to its right")
    func flipHorizontal() {
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(
            to: CGRect(x: 0, y: 0, width: 40, height: 90))
        let drawn = FlipHorizontalOverlayProvider().makeOverlay(parameters: [:])
            .render(over: white.composited(over: black), in: context())
        #expect(pixel(drawn, x: 10, y: 45)[0] == 0)
        #expect(pixel(drawn, x: 150, y: 45)[0] == 255)
        #expect(drawn.extent == bounds)
    }

    @Test("blue only shows the blue channel as grey")
    func blueOnly() {
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
        let overlay = BlueOnlyOverlayProvider().makeOverlay(parameters: [:])
        #expect(pixel(overlay.render(over: blue, in: context()), x: 80, y: 45) == [255, 255, 255, 255])
        #expect(pixel(overlay.render(over: red, in: context()), x: 80, y: 45) == [0, 0, 0, 255])
    }

    @Test("the zebra stripes a highlight and leaves a mid grey untouched")
    func zebra() {
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(
            to: CGRect(x: 0, y: 0, width: 80, height: 90))
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: bounds)
        let drawn = ZebraOverlayProvider().makeOverlay(parameters: [:])
            .render(over: white.composited(over: grey), in: context())
        // Pixel centers sum to a multiple of the 8-pixel period at (2, 45):
        // a dark band. Four pixels along, the band is clear.
        #expect(pixel(drawn, x: 2, y: 45)[0] < 200)
        #expect(pixel(drawn, x: 6, y: 45)[0] == 255)
        let greyBefore = pixel(grey, x: 82, y: 45)
        #expect(pixel(drawn, x: 82, y: 45) == greyBefore)
    }

    @Test("show alpha puts a checkerboard under the picture's transparent parts, inside the picture only")
    func showAlpha() {
        let drawable = CGRect(x: 0, y: 0, width: 160, height: 90)
        let pictureRect = CGRect(x: 40, y: 0, width: 80, height: 90)
        let inputContext = MonitorOverlayContext(
            monitor: .input, tally: .unlit, canvasSize: CGSize(width: 80, height: 90), pictureRect: pictureRect,
            drawableRect: drawable, backingScale: 1)
        let clear = CIImage(color: .clear).cropped(to: pictureRect)
        let drawn = ShowAlphaOverlayProvider().makeOverlay(parameters: [:]).render(over: clear, in: inputContext)
        let inside = pixel(drawn, x: 44, y: 4)
        #expect(inside[3] == 255)
        #expect(inside[0] > 100)
        #expect(pixel(drawn, x: 10, y: 45)[3] == 0)
        let opaque = black
        #expect(
            pixel(ShowAlphaOverlay().render(over: opaque, in: context()), x: 80, y: 45) == [0, 0, 0, 255])
    }

    @Test("the VU meters fill a bar from the bottom and draw nothing without levels")
    func vuMeters() {
        let overlay = VUMetersOverlayProvider().makeOverlay(parameters: [:])
        let level = MonitorOverlayContext.AudioLevel(peak: 1, rms: 1)
        let metered = MonitorOverlayContext(
            monitor: .program, tally: .program, canvasSize: CGSize(width: 1920, height: 1080), pictureRect: bounds,
            drawableRect: bounds, backingScale: 1, audioLevels: [level, level])
        let drawn = overlay.render(over: black, in: metered)
        // The first track is x 138 to 144, y 8 to 82: green near its foot.
        let foot = pixel(drawn, x: 140, y: 12)
        #expect(foot[1] > 150)
        #expect(foot[0] < 100)
        #expect(pixel(drawn, x: 80, y: 45) == [0, 0, 0, 255])
        #expect(pixel(overlay.render(over: black, in: context()), x: 140, y: 12) == [0, 0, 0, 255])
    }

    @Test("a fully transparent guide color draws nothing")
    func transparentColorDrawsNothing() {
        let overlay = CenterCrossOverlayProvider().makeOverlay(parameters: [
            "color": ParameterColor(red: 1, green: 1, blue: 1, alpha: 0).jsonValue
        ])
        let drawn = overlay.render(over: black, in: context())
        #expect(pixel(drawn, x: 80, y: 45) == [0, 0, 0, 255])
    }

    @Test("every overlay keeps the picture's extent")
    func extentKept() {
        for provider in MonitorPlugIn.providers {
            let drawn = provider.makeOverlay(parameters: [:]).render(over: black, in: context())
            #expect(drawn.extent == bounds, "\(provider.id.rawValue)")
        }
    }
}
