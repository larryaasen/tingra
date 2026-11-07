//
//  render-b3b.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

// The source of Tingra Cameras' app icon (direction B3b: a turquoise field, a silver-rimmed
// lens, and a royal-blue iris), drawn with Core Graphics at 1024 x 1024. Run it as a script:
//
//     swift docs/app-icons/render-b3b.swift [output.png]
//
// With no argument it writes tingra-cameras-icon-b3b-1024.png beside this file. The art is full
// bleed with no transparency, like the current icon, because macOS applies the icon mask itself.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The icon's edge length in pixels.
let size = 1024
/// The lens's center, the middle of the canvas.
let center = CGPoint(x: 512, y: 512)

/// Makes a CGColor from a hex RGB value and an alpha.
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

/// Makes a gradient from hex stops.
func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient? {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map { color($0.0) } as CFArray,
        locations: stops.map(\.1))
}

/// Fills a disc with a vertical linear gradient running top to bottom.
func fillDisc(_ context: CGContext, radius: CGFloat, top: UInt32, bottom: UInt32) {
    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.clip()
    if let fill = gradient([(top, 0), (bottom, 1)]) {
        context.drawLinearGradient(
            fill, start: CGPoint(x: center.x, y: center.y - radius), end: CGPoint(x: center.x, y: center.y + radius),
            options: [])
    }
    context.restoreGState()
}

/// Fills a disc with a radial gradient whose bright point sits up and to the left.
func fillRadialDisc(_ context: CGContext, radius: CGFloat, stops: [(UInt32, CGFloat)]) {
    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.clip()
    if let fill = gradient(stops) {
        let focus = CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.35)
        context.drawRadialGradient(
            fill, startCenter: focus, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    context.restoreGState()
}

guard
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else {
    print("Could not create the bitmap context.")
    exit(1)
}

// Work in a top-left, y-down space to match the sketch's coordinates.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

// Turquoise field, full bleed like the current art (macOS applies the icon mask).
if let field = gradient([(0x2DB8BD, 0), (0x1A9EA6, 0.55), (0x117C88, 1)]) {
    context.drawLinearGradient(field, start: .zero, end: CGPoint(x: 0, y: size), options: [])
}

// Lens body with a soft drop shadow onto the field.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 22), blur: 60, color: color(0x063E46, 0.55))
fillDisc(context, radius: 389, top: 0xFAFBFD, bottom: 0xC5CDD7)
context.restoreGState()

// Silver rim's inner bevel, then the barrel.
fillDisc(context, radius: 360, top: 0xB9C2CD, bottom: 0xEEF1F5)
fillDisc(context, radius: 348, top: 0x5E6977, bottom: 0x2C333D)
fillDisc(context, radius: 307, top: 0x050709, bottom: 0x141922)

// Royal-blue iris: outer element, inner element, pupil.
fillRadialDisc(context, radius: 256, stops: [(0x6FA2F5, 0), (0x3F7FEA, 0.55), (0x2A5FC8, 1)])
fillRadialDisc(context, radius: 174, stops: [(0x3A73DD, 0), (0x2B62CC, 0.6), (0x1F4BA6, 1)])
fillRadialDisc(context, radius: 82, stops: [(0x10131C, 0), (0x05060C, 1)])

// Specular arc on the glass, upper left.
context.setLineCap(.round)
context.setLineWidth(36)
context.setStrokeColor(color(0xFFFFFF, 0.55))
context.addArc(
    center: center, radius: 205, startAngle: 212 * .pi / 180, endAngle: 264 * .pi / 180, clockwise: false)
context.strokePath()

// Small turquoise reflection, lower right, echoing the field.
context.setFillColor(color(0x3FD0C9, 0.85))
context.fillEllipse(in: CGRect(x: 635 - 31, y: 635 - 31, width: 62, height: 62))

guard let image = context.makeImage() else {
    print("Could not make the image.")
    exit(1)
}
/// Where the PNG goes: the first argument, else beside this script.
let output =
    CommandLine.arguments.count > 1
    ? URL(filePath: CommandLine.arguments[1])
    : URL(filePath: #filePath).deletingLastPathComponent().appending(path: "tingra-cameras-icon-b3b-1024.png")
guard
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    print("Could not create the PNG destination.")
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    print("Could not write the PNG.")
    exit(1)
}
print("Wrote \(output.path)")
