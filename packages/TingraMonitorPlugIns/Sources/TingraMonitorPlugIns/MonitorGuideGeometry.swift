//
//  MonitorGuideGeometry.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics

/// The pure geometry of the first-party guides: where each one's lines go
/// inside the fitted picture. Kept apart from drawing so every rule is
/// unit-tested with no GPU.
///
/// Every rectangle is in drawable pixels, the space of
/// `MonitorOverlayContext.pictureRect`, and is snapped to whole pixels so
/// a line never blurs across two.
enum MonitorGuideGeometry {
    /// The centered rectangle covering `fraction` of the picture's width
    /// and height: a safe area. SMPTE ST 2046-1 puts the action safe area
    /// at 93 % and the title safe area at 90 %.
    ///
    /// - Parameters:
    ///   - picture: The fitted picture's rectangle.
    ///   - fraction: The share of each dimension kept, clamped to `0...1`.
    /// - Returns: The safe area, snapped to whole pixels.
    static func safeArea(in picture: CGRect, fraction: Double) -> CGRect {
        let kept = min(1, max(0, fraction))
        let insetX = picture.width * (1 - kept) / 2
        let insetY = picture.height * (1 - kept) / 2
        return snapped(picture.insetBy(dx: insetX, dy: insetY))
    }

    /// The largest rectangle of the given aspect ratio centered in the
    /// picture: what a crop to that aspect keeps.
    ///
    /// - Parameters:
    ///   - picture: The fitted picture's rectangle.
    ///   - aspect: Width over height, such as `9.0 / 16.0`.
    /// - Returns: The crop rectangle, snapped to whole pixels, or the
    ///   picture itself when the aspect is not a positive number.
    static func cropArea(in picture: CGRect, aspect: Double) -> CGRect {
        guard aspect > 0, aspect.isFinite, picture.width > 0, picture.height > 0 else { return picture }
        let pictureAspect = picture.width / picture.height
        let size: CGSize
        if pictureAspect > aspect {
            size = CGSize(width: picture.height * aspect, height: picture.height)
        } else {
            size = CGSize(width: picture.width, height: picture.width / aspect)
        }
        let origin = CGPoint(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2)
        return snapped(CGRect(origin: origin, size: size))
    }

    /// Whether two aspect ratios are close enough to count as the same: a
    /// 1920×1080 canvas is 16:9 even though 1080 is not a multiple of 9 at
    /// every size. Within half a percent.
    ///
    /// - Parameters:
    ///   - lhs: One aspect, width over height.
    ///   - rhs: The other.
    /// - Returns: Whether they match.
    static func aspectsMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs > 0, rhs > 0 else { return false }
        return abs(lhs / rhs - 1) < 0.005
    }

    /// The four strips of a rectangle's outline, each `lineWidth` thick,
    /// drawn inside the rectangle so the outline never spills past it.
    ///
    /// - Parameters:
    ///   - rect: The rectangle to outline.
    ///   - lineWidth: The line's thickness in pixels.
    /// - Returns: The bottom, top, left, and right strips; none for an
    ///   empty rectangle or a non-positive width.
    static func outline(of rect: CGRect, lineWidth: CGFloat) -> [CGRect] {
        guard !rect.isEmpty, lineWidth > 0 else { return [] }
        let width = min(lineWidth, rect.width / 2, rect.height / 2)
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: width),
            CGRect(x: rect.minX, y: rect.maxY - width, width: rect.width, height: width),
            CGRect(x: rect.minX, y: rect.minY + width, width: width, height: rect.height - 2 * width),
            CGRect(x: rect.maxX - width, y: rect.minY + width, width: width, height: rect.height - 2 * width),
        ].map(snapped)
    }

    /// The two arms of a cross at the picture's center, each `armFraction`
    /// of the picture's shorter side long in total.
    ///
    /// - Parameters:
    ///   - picture: The fitted picture's rectangle.
    ///   - armFraction: The cross's span as a share of the shorter side.
    ///   - lineWidth: The line's thickness in pixels.
    /// - Returns: The horizontal arm, then the vertical one.
    static func centerCross(in picture: CGRect, armFraction: Double, lineWidth: CGFloat) -> [CGRect] {
        guard !picture.isEmpty, lineWidth > 0 else { return [] }
        let span = min(picture.width, picture.height) * min(1, max(0, armFraction))
        return [
            CGRect(x: picture.midX - span / 2, y: picture.midY - lineWidth / 2, width: span, height: lineWidth),
            CGRect(x: picture.midX - lineWidth / 2, y: picture.midY - span / 2, width: lineWidth, height: span),
        ].map(snapped)
    }

    /// The transform mirroring the plane left to right about a vertical
    /// line, leaving that line in place.
    ///
    /// - Parameter x: Where the mirror line is.
    /// - Returns: The transform taking a point at `x + d` to `x - d`.
    static func horizontalMirror(about x: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * x, ty: 0)
    }

    /// Two lines through the picture's center, each running edge to edge.
    ///
    /// - Parameters:
    ///   - picture: The fitted picture's rectangle.
    ///   - lineWidth: The line's thickness in pixels.
    /// - Returns: The horizontal line, then the vertical one.
    static func centerLines(in picture: CGRect, lineWidth: CGFloat) -> [CGRect] {
        guard !picture.isEmpty, lineWidth > 0 else { return [] }
        return [
            CGRect(x: picture.minX, y: picture.midY - lineWidth / 2, width: picture.width, height: lineWidth),
            CGRect(x: picture.midX - lineWidth / 2, y: picture.minY, width: lineWidth, height: picture.height),
        ].map(snapped)
    }

    /// The four lines dividing the picture into thirds: two vertical, then
    /// two horizontal.
    ///
    /// - Parameters:
    ///   - picture: The fitted picture's rectangle.
    ///   - lineWidth: The line's thickness in pixels.
    /// - Returns: The lines, each centered on its third.
    static func thirds(in picture: CGRect, lineWidth: CGFloat) -> [CGRect] {
        guard !picture.isEmpty, lineWidth > 0 else { return [] }
        let vertical = [1.0, 2.0].map { step in
            CGRect(
                x: picture.minX + picture.width * step / 3 - lineWidth / 2, y: picture.minY,
                width: lineWidth, height: picture.height)
        }
        let horizontal = [1.0, 2.0].map { step in
            CGRect(
                x: picture.minX, y: picture.minY + picture.height * step / 3 - lineWidth / 2,
                width: picture.width, height: lineWidth)
        }
        return (vertical + horizontal).map(snapped)
    }

    /// The parts of `outer` that `inner` does not cover, as up to four
    /// rectangles: what a crop guide shades.
    ///
    /// - Parameters:
    ///   - outer: The whole area.
    ///   - inner: The kept area, inside `outer`.
    /// - Returns: The bottom, top, left, and right bands with any area.
    static func bands(around inner: CGRect, in outer: CGRect) -> [CGRect] {
        let kept = inner.intersection(outer)
        guard !kept.isNull else { return [outer] }
        return [
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: kept.minY - outer.minY),
            CGRect(x: outer.minX, y: kept.maxY, width: outer.width, height: outer.maxY - kept.maxY),
            CGRect(x: outer.minX, y: kept.minY, width: kept.minX - outer.minX, height: kept.height),
            CGRect(x: kept.maxX, y: kept.minY, width: outer.maxX - kept.maxX, height: kept.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    /// The rectangle with its edges moved to the nearest whole pixel.
    ///
    /// - Parameter rect: The rectangle.
    /// - Returns: The snapped rectangle.
    static func snapped(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded()
        let minY = rect.minY.rounded()
        let maxX = rect.maxX.rounded()
        let maxY = rect.maxY.rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
