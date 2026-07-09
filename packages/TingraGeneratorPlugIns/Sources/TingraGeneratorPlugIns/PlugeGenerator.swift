//
//  PlugeGenerator.swift
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
import TingraPlugInKit

/// The PLUGE (Picture Line-Up Generation Equipment) video generator
/// (`--video-generator pluge`, see CLI.md).
///
/// Frames are synthesized on the injected clock's tick — one frame per tick,
/// stamped with the tick's master clock time — in the working format:
/// `IOSurface`-backed 32BGRA, SDR, tagged BT.709 (ARCHITECTURE.md, "Color
/// and pixel format conventions"). The pattern is static by design: it is a
/// calibration surface for reference black, below-black visibility, and
/// shadow detail rather than a motion test.
///
/// A class because the generator owns live stream state (the active frame
/// continuations `stop()` finishes); frame configuration is fixed at
/// creation, with the program pipeline's configuration plumbing arriving at
/// roadmap step 3.
public final class PlugeGenerator: Input, Sendable {
    /// The generator's stable input identifier, the exact
    /// `--video-generator` value.
    public static let inputID = InputID(rawValue: "pluge")

    /// The stable input identifier (`pluge`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "PLUGE"

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

    /// The shared continuation/task plumbing every consumer's frame stream
    /// runs through.
    private let stream = GeneratorStreamCoordinator<CapturedFrame>()

    /// Creates a PLUGE generator. Defaults match the CLI's program defaults
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
            makeRenderer: { PlugeRenderer(width: width, height: height, style: .practical) },
            render: { renderer, tickTime in renderer.render(at: tickTime) }
        )
    }

    /// Finishes every live frame stream. Safe to call more than once.
    public func stop() async {
        await stream.stopAll()
    }
}

/// The stricter broadcast-style PLUGE video generator
/// (`--video-generator pluge-strict`, see CLI.md).
///
/// Frames are synthesized on the injected clock's tick — one frame per tick,
/// stamped with the tick's master clock time — in the working format:
/// `IOSurface`-backed 32BGRA, SDR, tagged BT.709 (ARCHITECTURE.md, "Color
/// and pixel format conventions"). Unlike ``PlugeGenerator``, this layout is
/// intentionally sparse: reference black background plus the classic
/// below-black / reference-black / above-black trio, with no shadow ramp.
///
/// A class because the generator owns live stream state (the active frame
/// continuations `stop()` finishes); frame configuration is fixed at
/// creation, with the program pipeline's configuration plumbing arriving at
/// roadmap step 3.
public final class PlugeStrictGenerator: Input, Sendable {
    /// The generator's stable input identifier, the exact
    /// `--video-generator` value.
    public static let inputID = InputID(rawValue: "pluge-strict")

    /// The stable input identifier (`pluge-strict`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "PLUGE Strict"

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

    /// The shared continuation/task plumbing every consumer's frame stream
    /// runs through.
    private let stream = GeneratorStreamCoordinator<CapturedFrame>()

    /// Creates a strict PLUGE generator. Defaults match the CLI's program
    /// defaults (1920x1080 at 30 fps, see CLI.md "Compression").
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
            makeRenderer: { PlugeRenderer(width: width, height: height, style: .strict) },
            render: { renderer, tickTime in renderer.render(at: tickTime) }
        )
    }

    /// Finishes every live frame stream. Safe to call more than once.
    public func stop() async {
        await stream.stopAll()
    }
}

/// Draws a PLUGE pattern into pooled, `IOSurface`-backed 32BGRA pixel
/// buffers. Confined to a single rendering task — never crosses an
/// isolation boundary, so it needs no `Sendable`.
private final class PlugeRenderer {
    /// The available PLUGE layouts.
    enum Style {
        /// A practical engineering layout: classic trio plus a shadow ramp.
        case practical

        /// A stricter broadcast-style layout: sparse trio on reference black.
        case strict
    }

    /// Reference black in full-range RGB.
    private static let blackLevel = 16.0 / 255.0

    /// Slightly below reference black, for brightness calibration.
    private static let belowBlackLevel = 12.0 / 255.0

    /// Slightly above reference black, for shadow-detail calibration.
    private static let aboveBlackLevel = 20.0 / 255.0

    /// A ramp of dark gray patches that should separate cleanly when shadow
    /// detail is preserved.
    private static let shadowRampLevels = [20.0, 24.0, 28.0, 32.0, 40.0, 52.0, 64.0, 80.0].map { $0 / 255.0 }

    /// The frame width in pixels.
    private let width: Int

    /// The frame height in pixels.
    private let height: Int

    /// The layout style to render.
    private let style: Style

    /// The pixel buffer pool frames are drawn into: `IOSurface`-backed
    /// 32BGRA, CG-compatible for CPU drawing (acceptable for a calibration
    /// pattern; capture inputs stay GPU-resident).
    private let pool: CVPixelBufferPool?

    /// Creates a renderer and its buffer pool for the given geometry.
    init(width: Int, height: Int, style: Style) {
        self.width = width
        self.height = height
        self.style = style
        self.pool = GeneratorPixelBuffer.makePool(width: width, height: height)
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
        guard let context = GeneratorPixelBuffer.makeDrawingContext(width: width, height: height, buffer: buffer)
        else { return nil }

        drawBackground(in: context)
        switch style {
        case .practical:
            drawShadowRamp(in: context)
            drawPracticalPlugeBars(in: context)
        case .strict:
            drawStrictPlugeBars(in: context)
        }
        buffer.tagBT709()
        return CapturedFrame(pixelBuffer: buffer, presentationTime: time)
    }

    /// Fills the whole frame with reference black.
    private func drawBackground(in context: CGContext) {
        let level = Self.blackLevel
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }

    /// Draws a stepped dark-gray ramp across the upper half of the frame so
    /// crushed shadow detail is easy to spot.
    private func drawShadowRamp(in context: CGContext) {
        let rampRect = CGRect(
            x: CGFloat(width) * 0.12,
            y: CGFloat(height) * 0.22,
            width: CGFloat(width) * 0.76,
            height: CGFloat(height) * 0.26
        )
        let patchWidth = rampRect.width / CGFloat(Self.shadowRampLevels.count)
        for (index, level) in Self.shadowRampLevels.enumerated() {
            context.setFillColor(red: level, green: level, blue: level, alpha: 1)
            let x = rampRect.minX + patchWidth * CGFloat(index)
            let nextX =
                index == Self.shadowRampLevels.count - 1
                ? rampRect.maxX : rampRect.minX + patchWidth * CGFloat(index + 1)
            context.fill(
                CGRect(
                    x: x.rounded(.down), y: rampRect.minY, width: nextX.rounded(.up) - x.rounded(.down),
                    height: rampRect.height))
        }
    }

    /// Draws the classic below-black / reference-black / above-black trio in
    /// the lower third. A correct monitor setup hides the below-black bar,
    /// barely reveals reference black against the background, and clearly
    /// reveals the above-black bar.
    private func drawPracticalPlugeBars(in context: CGContext) {
        let barsRect = CGRect(
            x: CGFloat(width) * 0.34,
            y: CGFloat(height) * 0.62,
            width: CGFloat(width) * 0.32,
            height: CGFloat(height) * 0.22
        )
        let gap = barsRect.width * 0.04
        let barWidth = (barsRect.width - gap * 2) / 3
        let levels = [Self.belowBlackLevel, Self.blackLevel, Self.aboveBlackLevel]
        for (index, level) in levels.enumerated() {
            context.setFillColor(red: level, green: level, blue: level, alpha: 1)
            let x = barsRect.minX + CGFloat(index) * (barWidth + gap)
            context.fill(CGRect(x: x, y: barsRect.minY, width: barWidth, height: barsRect.height))
        }
    }

    /// Draws the stricter broadcast-style trio as three narrow bars on a
    /// pure reference-black field, with no extra ramping or helper patches.
    private func drawStrictPlugeBars(in context: CGContext) {
        let barsRect = CGRect(
            x: CGFloat(width) * 0.39,
            y: CGFloat(height) * 0.18,
            width: CGFloat(width) * 0.22,
            height: CGFloat(height) * 0.56
        )
        let gap = barsRect.width * 0.06
        let barWidth = (barsRect.width - gap * 2) / 3
        let levels = [Self.belowBlackLevel, Self.blackLevel, Self.aboveBlackLevel]
        for (index, level) in levels.enumerated() {
            context.setFillColor(red: level, green: level, blue: level, alpha: 1)
            let x = barsRect.minX + CGFloat(index) * (barWidth + gap)
            context.fill(CGRect(x: x, y: barsRect.minY, width: barWidth, height: barsRect.height))
        }
    }
}
