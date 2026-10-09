//
//  WindowGeometry.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics

/// A window's size in physical pixels — what a window capture is configured
/// to deliver, so the frame carries the window at its own resolution and the
/// compositor scales it once, to the program format.
struct WindowPixelSize: Sendable, Equatable {
    /// The width in pixels.
    let width: Int

    /// The height in pixels.
    let height: Int

    /// The smallest side a capture is configured with. A window dragged
    /// down to nothing still has to be a frame.
    static let minimumSide = 2

    /// The pixel size of a window measured in points.
    ///
    /// - Parameters:
    ///   - pointSize: The window's size in points.
    ///   - scale: Pixels per point on the display showing it (2 on a Retina
    ///     panel).
    /// - Returns: The size, or nil when the measurement is not a size — a
    ///   zero or negative side, or a scale that is not a positive number.
    static func pixels(pointSize: CGSize, scale: Double) -> WindowPixelSize? {
        guard scale.isFinite, scale > 0, pointSize.width > 0, pointSize.height > 0 else { return nil }
        let width = (Double(pointSize.width) * scale).rounded()
        let height = (Double(pointSize.height) * scale).rounded()
        guard width.isFinite, height.isFinite else { return nil }
        return WindowPixelSize(width: max(Int(width), minimumSide), height: max(Int(height), minimumSide))
    }

    /// The window's own pixel size, read from what ScreenCaptureKit attaches
    /// to each frame of a window capture.
    ///
    /// A window capture's frame is the size the stream was **configured**
    /// with, not the window's: a window that has grown since is scaled down
    /// into the frame, and one that has shrunk sits in its top-left corner
    /// with the rest empty. The attachments say which happened — the
    /// content's rectangle within the frame in points, how far it was
    /// scaled to fit, and the display's pixels per point — and dividing the
    /// scaling back out gives the size to reconfigure to (measured
    /// 2026-10-08: a 920 × 436 point window in a 1000 × 1000 frame reports
    /// a 500 × 237 content rectangle at content scale 0.543 and scale
    /// factor 2, which is 1840 × 872).
    ///
    /// - Parameters:
    ///   - contentSize: The content rectangle's size within the frame, in
    ///     points.
    ///   - contentScale: How far the content was scaled to fit the frame;
    ///     1 when it was not.
    ///   - scaleFactor: The display's pixels per point.
    /// - Returns: The window's pixel size, or nil when the attachments do
    ///   not describe one.
    static func native(contentSize: CGSize, contentScale: Double, scaleFactor: Double) -> WindowPixelSize? {
        guard contentScale.isFinite, contentScale > 0 else { return nil }
        return pixels(pointSize: contentSize, scale: scaleFactor / contentScale)
    }
}
