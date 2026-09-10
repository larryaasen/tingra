//
//  MediaPixelBuffer.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreVideo

/// Shared pixel-buffer plumbing for the media inputs that draw their
/// picture on the CPU once — the still image and the text canvas. Movies
/// take their buffers from `AVAssetReader` instead, already `IOSurface`
/// backed.
enum MediaPixelBuffer {
    /// Creates one `IOSurface`-backed 32BGRA buffer, CG-compatible for CPU
    /// drawing, at the given geometry (ARCHITECTURE.md, "Color and pixel
    /// format conventions"). One buffer rather than a pool: a still is
    /// drawn once and held.
    ///
    /// - Throws: ``MediaInputError/pixelBufferUnavailable(_:)`` if Core
    ///   Video refuses.
    static func make(width: Int, height: Int) throws(MediaInputError) -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var bufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &bufferOut)
        guard status == kCVReturnSuccess, let buffer = bufferOut else { throw .pixelBufferUnavailable(status) }
        return buffer
    }

    /// Creates a `CGContext` that draws directly into `buffer`'s bytes,
    /// in sRGB so image content colour-matches on the way in — the one
    /// conversion, at input normalization. The caller must have already
    /// locked the buffer's base address.
    ///
    /// - Throws: ``MediaInputError/drawingContextUnavailable`` if Core
    ///   Graphics would not create one.
    static func drawingContext(for buffer: CVPixelBuffer) throws(MediaInputError) -> CGContext {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { throw .drawingContextUnavailable }
        return context
    }

    /// Tags the buffer BT.709 where no attachment is set, preserving any
    /// tags already present — a movie's track knows its colorimetry better
    /// than a default does. Every `CVPixelBuffer` in the pipeline carries
    /// color attachments; an untagged buffer is a defect.
    static func tagBT709IfUntagged(_ buffer: CVPixelBuffer) {
        let tags: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in tags where CVBufferCopyAttachment(buffer, key, nil) == nil {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }
}
