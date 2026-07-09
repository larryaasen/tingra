//
//  GeneratorStreaming.swift
//  TingraGeneratorPlugIns
//
//  Created by GitHub Copilot on 2026-07-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import TingraPlugInKit

/// Shared plumbing for every clock-paced generator `Input`: registers each
/// consumer's `AsyncStream` continuation, spins up a per-consumer synthesis
/// task that ticks the clock and yields renderer output, and tears every
/// live stream down together on ``stopAll()``.
///
/// Generic over the output type so the same coordinator backs both video
/// generators (yielding `CapturedFrame`) and the audio generator (yielding
/// `CapturedAudio`). The per-stream renderer is created inside the
/// synthesis task and never leaves it — per the frame ownership rule
/// (ARCHITECTURE.md) — so `makeStream`'s `Renderer` type parameter needs no
/// `Sendable` conformance even though the coordinator itself is `Sendable`.
final class GeneratorStreamCoordinator<Output: Sendable>: Sendable {
    /// The live output streams, so ``stopAll()`` can finish every consumer.
    private let continuations = Mutex<[UUID: AsyncStream<Output>.Continuation]>([:])

    /// Creates the coordinator for one generator instance.
    init() {}

    /// Creates a new tick-paced output stream, registering its continuation
    /// so ``stopAll()`` can finish it later.
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis and stamps output times.
    ///   - tickInterval: The clock tick cadence (one output per tick).
    ///   - makeRenderer: Creates the per-stream renderer, called once
    ///     inside the synthesis task.
    ///   - render: Synthesizes one output for a tick's master clock time,
    ///     or nil to skip a failed tick — a generator problem must never
    ///     take down the pipeline.
    func makeStream<Renderer>(
        clock: any EngineClock,
        tickInterval: CMTime,
        makeRenderer: @escaping @Sendable () -> Renderer,
        render: @escaping @Sendable (Renderer, CMTime) -> Output?
    ) -> AsyncStream<Output> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            let task = Task {
                // The renderer lives entirely inside this task; output
                // leaves it only through the yield, per the frame
                // ownership rule (ARCHITECTURE.md).
                let renderer = makeRenderer()
                for await tickTime in clock.tick(every: tickInterval) {
                    guard !Task.isCancelled else { break }
                    if let output = render(renderer, tickTime) {
                        continuation.yield(output)
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

    /// Finishes every live output stream. Safe to call more than once.
    func stopAll() async {
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

/// Shared pixel-buffer plumbing for the video generators' CPU-drawn test
/// patterns (acceptable for test patterns; capture inputs stay
/// GPU-resident, see ARCHITECTURE.md "Color and pixel format conventions").
enum GeneratorPixelBuffer {
    /// Creates an `IOSurface`-backed 32BGRA pixel buffer pool, CG-compatible
    /// for CPU drawing, at the given geometry.
    static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// Creates a `CGContext` that draws directly into `buffer`'s bytes, or
    /// nil if Core Graphics could not create one. The caller must have
    /// already locked the buffer's base address.
    static func makeDrawingContext(width: Int, height: Int, buffer: CVPixelBuffer) -> CGContext? {
        CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}

extension CVPixelBuffer {
    /// Tags the buffer BT.709 — every `CVPixelBuffer` in the pipeline
    /// carries color attachments; an untagged buffer is a defect
    /// (ARCHITECTURE.md, "Color and pixel format conventions").
    func tagBT709() {
        CVBufferSetAttachment(
            self,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            self,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            self,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }
}
