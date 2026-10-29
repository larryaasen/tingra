//
//  FrameClipboard.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import CoreImage

/// Turns a camera frame into an image and puts it on the general pasteboard
/// — what Copy does with the preview's current frame.
enum FrameClipboard {
    /// The Core Image context every copy renders through, made once: a
    /// context is costly to create and safe to reuse.
    private static let context = CIContext()

    /// Renders a camera frame as an 8-bit sRGB image, the form every app
    /// that pastes a picture accepts. Core Image reads the frame's color
    /// tags (BT.709 for a camera, per the color conventions in
    /// ARCHITECTURE.md) and converts from them.
    ///
    /// - Parameter pixelBuffer: The camera frame.
    /// - Returns: The image, or nil when it cannot be rendered.
    static func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.createCGImage(frame, from: frame.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Replaces the general pasteboard's contents with an image, at its
    /// full pixel size.
    ///
    /// - Parameter image: The image to copy.
    static func copy(_ image: CGImage) {
        let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([picture])
    }
}
