//
//  CoreImageShotRenderer.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreMedia
import CoreVideo
import Metal
import TingraPlugInKit

/// The default ``ShotRenderer``: composites a shot's layer tree with Core
/// Image, GPU-resident through a Metal-backed `CIContext`
/// (ARCHITECTURE.md, "Composition" — Core Image supplies compositing
/// without hand-writing every shader; raw Metal shaders arrive only where
/// custom work or performance demands them, at the effects/transitions
/// step).
///
/// The pipeline stays on the GPU: each layer's `IOSurface`-backed
/// `CVPixelBuffer` becomes a `CIImage`, is scaled and placed into its
/// destination rect, and is composited over the background; the result
/// renders into an `IOSurface`-backed 32BGRA program buffer, tagged BT.709
/// (the delivery convention every buffer in the pipeline carries).
///
/// Not `Sendable` by design (see ``ShotRenderer``): an instance and its
/// `CIContext` and buffer pool live entirely inside the compositor's tick
/// task, so nothing here crosses an isolation boundary.
public final class CoreImageShotRenderer: ShotRenderer {
    /// The Core Image context that runs the compositing graph. Metal-backed
    /// in production; tests inject a software context for deterministic,
    /// GPU-free pixel checks.
    private let context: CIContext

    /// The output color space Core Image renders into: sRGB, tagged BT.709
    /// on the buffer afterward — the same SDR convention the generators use
    /// (their working space is device RGB with BT.709 tags).
    private let outputColorSpace: CGColorSpace

    /// The output buffer pool, `IOSurface`-backed 32BGRA. Created lazily for
    /// the program size and rebuilt if the size changes.
    private var pool: CVPixelBufferPool?

    /// The size the current ``pool`` produces, so a format change rebuilds it.
    private var poolSize: (width: Int, height: Int)?

    /// Creates the production renderer, Metal-backed where a GPU is present.
    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device)
        } else {
            self.context = CIContext()
        }
        self.outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Creates a renderer over an injected Core Image context (the test
    /// seam): a software `CIContext` makes compositing deterministic and
    /// GPU-free for unit tests.
    ///
    /// - Parameter context: The Core Image context to render with.
    init(context: CIContext) {
        self.context = context
        self.outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Composites the shot's layer tree into one program frame.
    public func render(
        shot: Shot,
        frames: [InputID: CapturedFrame],
        format: ProgramFormat,
        time: CMTime
    ) -> CapturedFrame? {
        guard let buffer = makeOutputBuffer(width: format.width, height: format.height) else { return nil }

        let programRect = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        var image = backgroundImage(shot.background, in: programRect)
        for layer in shot.layers {
            guard let frame = frames[layer.input] else { continue }
            if let placed = placedImage(for: frame, layer: layer, format: format) {
                image = placed.composited(over: image)
            }
        }

        context.render(image, to: buffer, bounds: programRect, colorSpace: outputColorSpace)
        tagBT709(buffer)
        return CapturedFrame(pixelBuffer: buffer, presentationTime: time)
    }

    /// The background as an infinite color image cropped to the program.
    private func backgroundImage(_ color: BackgroundColor, in rect: CGRect) -> CIImage {
        let ciColor = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        return CIImage(color: ciColor).cropped(to: rect)
    }

    /// One layer's frame, scaled into its destination rect (converting the
    /// layer's top-left-origin normalized frame into Core Image's
    /// bottom-left pixel space) and faded to its opacity. Returns nil when
    /// the destination is empty (a zero-size layer draws nothing).
    private func placedImage(for frame: CapturedFrame, layer: Layer, format: ProgramFormat) -> CIImage? {
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let sourceExtent = source.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }

        let width = Double(format.width)
        let height = Double(format.height)
        let destWidth = layer.frame.width * width
        let destHeight = layer.frame.height * height
        guard destWidth > 0, destHeight > 0 else { return nil }
        let destX = layer.frame.minX * width
        // Flip the top-left-origin normalized frame into bottom-left pixels.
        let destY = height * (1 - layer.frame.minY - layer.frame.height)

        var transform = CGAffineTransform(scaleX: destWidth / sourceExtent.width, y: destHeight / sourceExtent.height)
        transform = transform.concatenating(CGAffineTransform(translationX: destX, y: destY))
        var placed = source.transformed(by: transform)

        let opacity = min(max(layer.opacity, 0), 1)
        if opacity < 1 {
            placed = placed.applyingFilter(
                "CIColorMatrix",
                parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)]
            )
        }
        return placed
    }

    /// Fetches (or lazily builds) the output buffer pool for the program
    /// size and vends one `IOSurface`-backed 32BGRA buffer, or nil if the
    /// pool or a buffer cannot be created.
    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if poolSize?.width != width || poolSize?.height != height {
            pool = Self.makePool(width: width, height: height)
            poolSize = pool == nil ? nil : (width, height)
        }
        guard let pool else { return nil }
        var bufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut) == kCVReturnSuccess else {
            return nil
        }
        return bufferOut
    }

    /// Builds an `IOSurface`-backed 32BGRA pixel buffer pool for the given
    /// size (the GPU-resident program buffer type).
    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// Tags the buffer BT.709 — every `CVPixelBuffer` in the pipeline
    /// carries color attachments; an untagged buffer is a defect
    /// (ARCHITECTURE.md, "Color and pixel format conventions").
    private func tagBT709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }
}
