//
//  BlackGenerator.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-08-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import TingraPlugInKit

/// A full-frame opaque black video generator (`--video-generator black`, see
/// CLI.md) — the **black generator** a switcher carries as a selectable input
/// on its rows (GLOSSARY.md, "Generator", which already covers solids).
///
/// **Upstream of fade to black, and complementary to it rather than an
/// alternative** (ARCHITECTURE.md, "Fade to black"). FTB is a downstream
/// master stage that obscures everything and latches the whole program off
/// air; this is an ordinary input bound into a layer, so overlays, keys, and
/// titles composite *over* it — cut the background to black and keep a lower
/// third up.
///
/// **Black-only, deliberately, and not a solid-colour generator with a
/// parameter.** ``Layer`` carries an input, a frame, an opacity, and an
/// effect chain — there is no per-layer parameter dictionary — so a settable
/// colour would need a new key in the persisted document, which is the one
/// cost this feature was scoped to avoid. Hanging the colour off this single
/// registered instance would be worse: every layer bound to it shares one
/// value, so setting the colour in one shot would silently change every other
/// shot that uses it. A shot's own `background` is already a full persisted
/// RGBA (defaulting to opaque black), so arbitrary solids are *already*
/// reachable; what they cannot be is **stacked as a layer**, which is exactly
/// and only what this adds. If other solids are ever wanted, the shape is
/// more registered generators beside this one — additive, still no seam and
/// still no document change.
///
/// Frames are synthesized on the injected clock's tick — one frame per tick,
/// stamped with the tick's master clock time (CLOCK.md, "Generators") — in
/// the working format: `IOSurface`-backed 32BGRA, SDR, tagged BT.709
/// (ARCHITECTURE.md, "Color and pixel format conventions").
///
/// A class because the generator owns live stream state (the active frame
/// continuations `stop()` finishes); frame configuration is fixed at
/// creation.
public final class BlackGenerator: Input, Sendable {
    /// The generator's stable input identifier, the exact
    /// `--video-generator` value.
    public static let inputID = InputID(rawValue: "black")

    /// The stable input identifier (`black`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "Black"

    /// Generators are their own input kind (see GLOSSARY.md).
    public let kind = InputKind.generator

    /// A picture, however plain: video only. The kind above cannot say this —
    /// which is the whole reason ``InputMedia`` exists.
    public let media = InputMedia.video

    /// The master clock (or a synthetic clock under test) whose tick paces
    /// frame synthesis and stamps each frame's PTS.
    private let clock: any EngineClock

    /// The frame width in pixels (kept even — 4:2:0 delivery requires it).
    private let width: Int

    /// The frame height in pixels (kept even — 4:2:0 delivery requires it).
    private let height: Int

    /// Frames synthesized per second.
    private let frameRate: Int

    /// The shared continuation/task plumbing every consumer's frame stream
    /// runs through.
    private let stream = GeneratorStreamCoordinator<CapturedFrame>()

    /// Creates a black generator. Defaults match the CLI's program defaults
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
        let width = self.width
        let height = self.height
        let frameRate = self.frameRate
        return stream.makeStream(
            clock: clock,
            tickInterval: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            makeRenderer: { BlackRenderer(width: width, height: height) },
            render: { renderer, tickTime in renderer.render(at: tickTime) }
        )
    }

    /// Finishes every live frame stream. Safe to call more than once.
    public func stop() async {
        await stream.stopAll()
    }
}

/// Fills pooled, `IOSurface`-backed 32BGRA pixel buffers with opaque black.
/// Confined to a single rendering task — never crosses an isolation
/// boundary, so it needs no `Sendable`.
private final class BlackRenderer {
    /// The frame width in pixels.
    private let width: Int

    /// The frame height in pixels.
    private let height: Int

    /// The pixel buffer pool frames are drawn into: `IOSurface`-backed
    /// 32BGRA, CG-compatible for CPU drawing (acceptable for a generated
    /// pattern; capture inputs stay GPU-resident).
    private let pool: CVPixelBufferPool?

    /// Creates a renderer and its buffer pool for the given geometry.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pool = GeneratorPixelBuffer.makePool(width: width, height: height)
    }

    /// Renders one opaque black frame for the given master clock time, or nil
    /// if a buffer or drawing context could not be created — a generator
    /// problem must never take down the pipeline, so a failed frame is simply
    /// skipped.
    func render(at time: CMTime) -> CapturedFrame? {
        guard let pool else { return nil }
        var bufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut)
        guard let buffer = bufferOut else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = GeneratorPixelBuffer.makeDrawingContext(width: width, height: height, buffer: buffer)
        else { return nil }

        // Filled explicitly on every tick rather than once: a pool recycles
        // buffers and does not guarantee their contents, so a buffer handed
        // back here still holds whatever the previous frame left in it. The
        // alpha matters as much as the color — a layer composites with it,
        // and a transparent "black" frame would show the layers beneath.
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        buffer.tagBT709()
        return CapturedFrame(pixelBuffer: buffer, presentationTime: time)
    }
}
