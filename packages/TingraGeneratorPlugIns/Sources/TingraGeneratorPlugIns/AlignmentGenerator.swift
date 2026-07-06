//
//  AlignmentGenerator.swift
//  TingraGeneratorPlugIns
//
//  Created by GitHub Copilot on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import TingraPlugInKit

/// An industry-standard-style alignment pattern video generator
/// (`--video-generator alignment`, see CLI.md).
///
/// Frames are synthesized on the injected clock's tick — one frame per tick,
/// stamped with the tick's master clock time — in the working format:
/// `IOSurface`-backed 32BGRA, SDR, tagged BT.709 (ARCHITECTURE.md, "Color
/// and pixel format conventions"). The pattern itself is immutable: it is
/// rendered once when the renderer is created, cached as a `CGImage`, and
/// copied into a fresh pixel buffer for each yielded frame so the frame
/// ownership rule stays intact.
///
/// A class because the generator owns live stream state (the active frame
/// continuations `stop()` finishes); frame configuration is fixed at
/// creation, with the program pipeline's configuration plumbing arriving at
/// roadmap step 3.
public final class AlignmentGenerator: Input, Sendable {
    /// The generator's stable input identifier, the exact
    /// `--video-generator` value.
    public static let inputID = InputID(rawValue: "alignment")

    /// The stable input identifier (`alignment`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "Alignment Pattern"

    /// Generators are their own input kind (see GLOSSARY.md).
    public let kind = InputKind.generator

    /// The master clock (or a synthetic clock under test) whose tick paces
    /// frame synthesis and stamps each frame's PTS.
    private let clock: any EngineClock

    /// The frame width in pixels (kept even — 4:2:0 delivery requires it).
    private let width: Int

    /// The frame height in pixels (kept even — 4:2:0 delivery requires it).
    private let height: Int

    /// Frames synthesized per second.
    private let frameRate: Int

    /// The live frame streams, so `stop()` can finish every consumer.
    private let continuations = Mutex<[UUID: AsyncStream<CapturedFrame>.Continuation]>([:])

    /// Creates an alignment-pattern generator. Defaults match the CLI's
    /// program defaults (1920x1080 at 30 fps, see CLI.md "Compression").
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis and stamps frames.
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - frameRate: Frames per second.
    public init(clock: any EngineClock, width: Int = 1920, height: Int = 1080, frameRate: Int = 30) {
        self.clock = clock
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// Nothing to acquire — a generator has no device and cannot be denied
    /// authorization, so starting never throws.
    public func start() async throws {}

    /// One synthesized frame per clock tick, stamped with the tick's time.
    /// The stream finishes when the tick stream ends, the consumer stops
    /// consuming, or ``stop()`` is called.
    public func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            let clock = self.clock
            let width = self.width
            let height = self.height
            let frameRate = self.frameRate
            let task = Task {
                // The renderer (and its cached pattern image) lives entirely
                // inside this task; frames leave it only through the yield,
                // per the frame ownership rule (ARCHITECTURE.md).
                let renderer = AlignmentRenderer(width: width, height: height)
                for await tickTime in clock.tick(every: CMTime(value: 1, timescale: CMTimeScale(frameRate))) {
                    guard !Task.isCancelled else { break }
                    if let frame = renderer.render(at: tickTime) {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.continuations.withLock { $0[id] = nil }
            }
        }
    }

    /// Finishes every live frame stream. Safe to call more than once.
    public func stop() async {
        let active = continuations.withLock { store in
            let values = Array(store.values)
            store.removeAll()
            return values
        }
        for continuation in active {
            continuation.finish()
        }
    }
}

/// Draws and caches an alignment pattern, then copies it into fresh
/// `IOSurface`-backed 32BGRA pixel buffers for each output frame. Confined
/// to a single rendering task — never crosses an isolation boundary, so it
/// needs no `Sendable`.
private final class AlignmentRenderer {
    /// The dark neutral background used for the alignment field.
    private static let backgroundLevel = 48.0 / 255.0

    /// The grid-line brightness.
    private static let gridLevel = 168.0 / 255.0

    /// The safe-area-box brightness.
    private static let safeBoxLevel = 208.0 / 255.0

    /// The brightest markings: border and center cross.
    private static let markerLevel = 1.0

    /// The frame width in pixels.
    private let width: Int

    /// The frame height in pixels.
    private let height: Int

    /// The pixel buffer pool frames are drawn into: `IOSurface`-backed
    /// 32BGRA, CG-compatible for CPU drawing (acceptable for a test
    /// pattern; capture inputs stay GPU-resident).
    private let pool: CVPixelBufferPool?

    /// The immutable cached alignment image generated once at renderer
    /// creation and copied into every fresh frame buffer thereafter.
    private let cachedPattern: CGImage?

    /// Creates a renderer, its buffer pool, and the cached alignment image
    /// for the given geometry.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        self.pool = pool
        self.cachedPattern = Self.makePatternImage(width: width, height: height)
    }

    /// Renders one frame for the given master clock time, or nil if a
    /// buffer or drawing context could not be created — a generator
    /// problem must never take down the pipeline, so a failed frame is
    /// simply skipped.
    func render(at time: CMTime) -> CapturedFrame? {
        guard let pool, let cachedPattern else { return nil }
        var bufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut)
        guard let buffer = bufferOut else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return nil }

        context.draw(cachedPattern, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        tagBT709(buffer)
        return CapturedFrame(pixelBuffer: buffer, presentationTime: time)
    }

    /// Builds the cached pattern image once for the requested geometry.
    private static func makePatternImage(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return nil }

        context.setShouldAntialias(false)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        drawBackground(in: context, bounds: bounds)
        drawGrid(in: context, bounds: bounds)
        drawSafeBoxes(in: context, bounds: bounds)
        drawCenterCross(in: context, bounds: bounds)
        drawRegistrationCircle(in: context, bounds: bounds)
        drawBorder(in: context, bounds: bounds)
        return context.makeImage()
    }

    /// Fills the whole frame with the dark neutral background.
    private static func drawBackground(in context: CGContext, bounds: CGRect) {
        let level = Self.backgroundLevel
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        context.fill(bounds)
    }

    /// Draws a 10% crosshatch grid across the frame.
    private static func drawGrid(in context: CGContext, bounds: CGRect) {
        let thickness = max(1, Int(min(bounds.width, bounds.height) / 540))
        let level = Self.gridLevel
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        for step in 1..<10 {
            let x = Int((bounds.width * CGFloat(step) / 10).rounded(.down))
            fillVerticalLine(in: context, x: x, thickness: thickness, height: Int(bounds.height))
            let y = Int((bounds.height * CGFloat(step) / 10).rounded(.down))
            fillHorizontalLine(in: context, y: y, thickness: thickness, width: Int(bounds.width))
        }
    }

    /// Draws safe-area guide boxes inside the grid.
    private static func drawSafeBoxes(in context: CGContext, bounds: CGRect) {
        let thickness = max(1, Int(min(bounds.width, bounds.height) / 360))
        let level = Self.safeBoxLevel
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        for insetFraction in [0.1, 0.2] {
            let insetX = Int((bounds.width * insetFraction).rounded(.down))
            let insetY = Int((bounds.height * insetFraction).rounded(.down))
            let rect = CGRect(
                x: CGFloat(insetX),
                y: CGFloat(insetY),
                width: bounds.width - CGFloat(insetX * 2),
                height: bounds.height - CGFloat(insetY * 2)
            )
            fillRectangleBorder(in: context, rect: rect, thickness: thickness)
        }
    }

    /// Draws the center cross used for registration and geometry checks.
    private static func drawCenterCross(in context: CGContext, bounds: CGRect) {
        let thickness = max(2, Int(min(bounds.width, bounds.height) / 180))
        let level = Self.markerLevel
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        let centerX = Int((bounds.width / 2).rounded(.down))
        let centerY = Int((bounds.height / 2).rounded(.down))
        fillVerticalLine(in: context, x: centerX - thickness / 2, thickness: thickness, height: Int(bounds.height))
        fillHorizontalLine(in: context, y: centerY - thickness / 2, thickness: thickness, width: Int(bounds.width))
    }

    /// Draws a registration circle centered in the frame.
    private static func drawRegistrationCircle(in context: CGContext, bounds: CGRect) {
        let level = Self.safeBoxLevel
        context.setStrokeColor(red: level, green: level, blue: level, alpha: 1)
        context.setLineWidth(max(1, min(bounds.width, bounds.height) / 540))
        let diameter = min(bounds.width, bounds.height) * 0.55
        let circle = CGRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        context.strokeEllipse(in: circle)
    }

    /// Draws the bright outer border.
    private static func drawBorder(in context: CGContext, bounds: CGRect) {
        let thickness = max(2, Int(min(bounds.width, bounds.height) / 180))
        let level = Self.markerLevel
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        fillRectangleBorder(in: context, rect: bounds, thickness: thickness)
    }

    /// Fills one vertical line segment as a rectangle for crisp pixel edges.
    private static func fillVerticalLine(in context: CGContext, x: Int, thickness: Int, height: Int) {
        context.fill(CGRect(x: x, y: 0, width: thickness, height: height))
    }

    /// Fills one horizontal line segment as a rectangle for crisp pixel edges.
    private static func fillHorizontalLine(in context: CGContext, y: Int, thickness: Int, width: Int) {
        context.fill(CGRect(x: 0, y: y, width: width, height: thickness))
    }

    /// Fills a rectangle border using four rectangles instead of stroked
    /// paths so the edges stay pixel-stable for tests.
    private static func fillRectangleBorder(in context: CGContext, rect: CGRect, thickness: Int) {
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: CGFloat(thickness)))
        context.fill(
            CGRect(x: rect.minX, y: rect.maxY - CGFloat(thickness), width: rect.width, height: CGFloat(thickness)))
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: CGFloat(thickness), height: rect.height))
        context.fill(
            CGRect(x: rect.maxX - CGFloat(thickness), y: rect.minY, width: CGFloat(thickness), height: rect.height))
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
