//
//  BarsGenerator.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import Synchronization
import TingraPlugInKit

/// The SMPTE color bars video generator with burned in timecode
/// (`--video-generator bars`, see CLI.md).
///
/// Frames are synthesized on the injected clock's tick — one frame per tick,
/// stamped with the tick's master clock time (CLOCK.md, "Generators") — in
/// the working format: `IOSurface`-backed 32BGRA, SDR, tagged BT.709
/// (ARCHITECTURE.md, "Color and pixel format conventions"). Under a
/// synthetic clock the generator is fully deterministic, which is what makes
/// it the CI test surface.
///
/// A class because the generator owns live stream state (the active frame
/// continuations `stop()` finishes); frame configuration is fixed at
/// creation, with the program pipeline's configuration plumbing arriving at
/// roadmap step 3.
public final class BarsGenerator: Input, Sendable {
    /// The generator's stable input identifier, the exact
    /// `--video-generator` value.
    public static let inputID = InputID(rawValue: "bars")

    /// The stable input identifier (`bars`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "SMPTE Bars"

    /// Generators are their own input kind (see GLOSSARY.md).
    public let kind = InputKind.generator

    /// The master clock (or a synthetic clock under test) whose tick paces
    /// frame synthesis and stamps each frame's PTS.
    private let clock: any EngineClock

    /// The frame width in pixels (kept even — 4:2:0 delivery requires it).
    private let width: Int

    /// The frame height in pixels (kept even — 4:2:0 delivery requires it).
    private let height: Int

    /// Frames synthesized per second; also the timecode's frame base.
    private let frameRate: Int

    /// The live frame streams, so `stop()` can finish every consumer.
    private let continuations = Mutex<[UUID: AsyncStream<CapturedFrame>.Continuation]>([:])

    /// Creates a bars generator. Defaults match the CLI's program defaults
    /// (1920x1080 at 30 fps, see CLI.md "Compression").
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
                // The renderer (and its pixel buffer pool) lives entirely
                // inside this task; frames leave it only through the yield,
                // per the frame ownership rule (ARCHITECTURE.md).
                let renderer = BarsRenderer(width: width, height: height, frameRate: frameRate)
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

/// Draws the bars pattern with burned in timecode into pooled,
/// `IOSurface`-backed 32BGRA pixel buffers. Confined to a single rendering
/// task — never crosses an isolation boundary, so it needs no `Sendable`.
private final class BarsRenderer {
    /// The classic 75% intensity SMPTE bar colors, left to right: gray,
    /// yellow, cyan, green, magenta, red, blue.
    private static let barColors: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = [
        (0.75, 0.75, 0.75),
        (0.75, 0.75, 0.0),
        (0.0, 0.75, 0.75),
        (0.0, 0.75, 0.0),
        (0.75, 0.0, 0.75),
        (0.75, 0.0, 0.0),
        (0.0, 0.0, 0.75),
    ]

    /// The frame width in pixels.
    private let width: Int

    /// The frame height in pixels.
    private let height: Int

    /// The timecode's frame base (frames per second).
    private let frameRate: Int

    /// The pixel buffer pool frames are drawn into: `IOSurface`-backed
    /// 32BGRA, CG-compatible for CPU drawing (acceptable for a test
    /// pattern; capture inputs stay GPU-resident).
    private let pool: CVPixelBufferPool?

    /// The timecode font, sized relative to the frame height.
    private let font: CTFont

    /// Creates a renderer and its buffer pool for the given geometry.
    init(width: Int, height: Int, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
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
        self.font = CTFontCreateWithName("Menlo-Bold" as CFString, CGFloat(height) / 12, nil)
    }

    /// Renders one frame for the given master clock time, or nil if a
    /// buffer or drawing context could not be created — a generator
    /// problem must never take down the pipeline, so a failed frame is
    /// simply skipped.
    func render(at time: CMTime) -> CapturedFrame? {
        guard let pool else { return nil }
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

        drawBars(in: context)
        drawTimecode(timecode(at: time), in: context)
        tagBT709(buffer)
        return CapturedFrame(pixelBuffer: buffer, presentationTime: time)
    }

    /// Fills the frame with the seven vertical 75% bars.
    private func drawBars(in context: CGContext) {
        let barWidth = CGFloat(width) / CGFloat(Self.barColors.count)
        for (index, color) in Self.barColors.enumerated() {
            // Device-space fill: the context's space is the buffer's space,
            // so 0.75 lands as exactly the intended byte value.
            context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
            // Overlap each bar's right edge onto the next to avoid seam
            // gaps from fractional bar widths; the last bar closes the row.
            let x = (barWidth * CGFloat(index)).rounded(.down)
            let nextX =
                index == Self.barColors.count - 1 ? CGFloat(width) : (barWidth * CGFloat(index + 1)).rounded(.up)
            context.fill(CGRect(x: x, y: 0, width: nextX - x, height: CGFloat(height)))
        }
    }

    /// Burns the timecode into the lower third: white monospaced text on a
    /// black box, centered horizontally.
    private func drawTimecode(_ timecode: String, in context: CGContext) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        guard
            let attributed = CFAttributedStringCreate(
                kCFAllocatorDefault,
                timecode as CFString,
                attributes as CFDictionary
            )
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        let padding = textBounds.height / 2
        let boxWidth = textBounds.width + padding * 2
        let boxHeight = textBounds.height + padding
        let boxOrigin = CGPoint(x: (CGFloat(width) - boxWidth) / 2, y: CGFloat(height) / 5)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(origin: boxOrigin, size: CGSize(width: boxWidth, height: boxHeight)))

        context.textPosition = CGPoint(
            x: boxOrigin.x + padding,
            y: boxOrigin.y + (boxHeight - textBounds.height) / 2 - textBounds.minY
        )
        CTLineDraw(line, context)
    }

    /// The `HH:MM:SS:FF` timecode for a master clock time, using the
    /// generator's frame rate as the frame base.
    private func timecode(at time: CMTime) -> String {
        let totalFrames = max(0, Int((time.seconds * Double(frameRate)).rounded()))
        let totalSeconds = totalFrames / frameRate
        let components = [
            (totalSeconds / 3600) % 100,
            (totalSeconds / 60) % 60,
            totalSeconds % 60,
            totalFrames % frameRate,
        ]
        return components.map { $0.formatted(.number.precision(.integerLength(2...))) }.joined(separator: ":")
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
