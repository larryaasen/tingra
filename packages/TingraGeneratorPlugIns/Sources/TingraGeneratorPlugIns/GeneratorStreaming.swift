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
import TingraEventBus
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
    /// A tick whose renderer throws is skipped rather than propagated — a
    /// generator problem must never take down the pipeline (ARCHITECTURE.md)
    /// — but the *episode* is reported on the bus, one `error` on the first
    /// skipped tick and one `event` on the first tick that recovers (see
    /// ``StallReporter`` and EVENTS.md, "Reporting a repeating failure").
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis and stamps output times.
    ///   - tickInterval: The clock tick cadence (one output per tick).
    ///   - inputID: The generator's identifier, reported with a stall.
    ///   - eventBus: The host's event bus; when absent nothing is reported
    ///     and skipping behaves exactly as before.
    ///   - makeRenderer: Creates the per-stream renderer, called once
    ///     inside the synthesis task.
    ///   - render: Synthesizes one output for a tick's master clock time, or
    ///     throws to skip the tick and open (or continue) a stall episode.
    func makeStream<Renderer>(
        clock: any EngineClock,
        tickInterval: CMTime,
        inputID: InputID,
        eventBus: EventBus?,
        makeRenderer: @escaping @Sendable () -> Renderer,
        render: @escaping @Sendable (Renderer, CMTime) throws(GeneratorSynthesisFailure) -> Output
    ) -> AsyncStream<Output> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            let task = Task {
                // The renderer lives entirely inside this task; output
                // leaves it only through the yield, per the frame
                // ownership rule (ARCHITECTURE.md). The stall reporter is
                // task-local for the same reason it is per stream: the
                // resource that fails belongs to this renderer alone.
                let renderer = makeRenderer()
                var stall = StallReporter(inputID: inputID, eventBus: eventBus)
                for await tickTime in clock.tick(every: tickInterval) {
                    guard !Task.isCancelled else { break }
                    do throws(GeneratorSynthesisFailure) {
                        let output = try render(renderer, tickTime)
                        stall.recordOutput()
                        continuation.yield(output)
                    } catch {
                        stall.recordFailure(error)
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

/// The buffer pool every video generator draws its CPU-rendered test pattern
/// into (acceptable for test patterns; capture inputs stay GPU-resident, see
/// ARCHITECTURE.md "Color and pixel format conventions").
///
/// A type rather than a bare `CVPixelBufferPool?` so the status of the failed
/// call survives to the tick that reports it: pool creation happens in a
/// renderer's initializer, which has no way to report anything — nothing
/// consumes a renderer until its first tick — so the failure is held here and
/// thrown from ``buffer()`` instead.
struct GeneratorPixelBufferPool {
    /// The pool, or nil if creation was refused.
    private let pool: CVPixelBufferPool?

    /// The `CVPixelBufferPoolCreate` status, kept so a renderer that never
    /// got a pool can still say why on every tick it skips.
    private let creationStatus: CVReturn

    /// Creates an `IOSurface`-backed 32BGRA pool, CG-compatible for CPU
    /// drawing, at the given geometry. Never throws — a refused pool surfaces
    /// at the first ``buffer()`` call.
    init(width: Int, height: Int) {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        creationStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        self.pool = pool
    }

    /// A fresh buffer from the pool.
    ///
    /// - Throws: ``GeneratorSynthesisFailure/pixelBufferPoolUnavailable(_:)``
    ///   if there was never a pool, or
    ///   ``GeneratorSynthesisFailure/pixelBufferUnavailable(_:)`` if the pool
    ///   would not vend one — the exhaustion case, and the reason a stall is
    ///   worth reporting as an episode that can end.
    func buffer() throws(GeneratorSynthesisFailure) -> CVPixelBuffer {
        guard let pool else { throw .pixelBufferPoolUnavailable(creationStatus) }
        var bufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut)
        guard let buffer = bufferOut else { throw .pixelBufferUnavailable(status) }
        return buffer
    }
}

/// Shared drawing plumbing for the video generators' CPU-drawn test patterns.
enum GeneratorPixelBuffer {
    /// Creates a `CGContext` that draws directly into `buffer`'s bytes. The
    /// caller must have already locked the buffer's base address.
    ///
    /// - Throws: ``GeneratorSynthesisFailure/drawingContextUnavailable`` if
    ///   Core Graphics would not create one.
    static func makeDrawingContext(
        width: Int,
        height: Int,
        buffer: CVPixelBuffer
    ) throws(GeneratorSynthesisFailure) -> CGContext {
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
        else { throw .drawingContextUnavailable }
        return context
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
