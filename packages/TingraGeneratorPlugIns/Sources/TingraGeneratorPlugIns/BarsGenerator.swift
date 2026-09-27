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
import TingraEventBus
import TingraPlugInKit

/// The SMPTE color bars video generator with burned in time-of-day timecode
/// (`--video-generator bars`, see CLI.md).
///
/// Frames are synthesized on the injected clock's tick — one frame per tick,
/// stamped with the tick's master clock time (CLOCK.md, "Generators") — in
/// the working format: `IOSurface`-backed 32BGRA, SDR, tagged BT.709
/// (ARCHITECTURE.md, "Color and pixel format conventions"). Under a
/// synthetic clock and a fixed wall clock the generator is fully
/// deterministic, which is what makes it the CI test surface.
///
/// The burned in timecode is the **local time of day** each frame stands for
/// (``BarsTimecode``), not the master clock itself: the master clock counts
/// the Mac's awake time since boot, which read as a plausible but wrong time
/// of day (Larry, 2026-09-27). A time of day also lets a viewer estimate the
/// stream's delay against any clock. Only the picture changes — the frame is
/// still stamped with the tick's master clock time.
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

    /// A test pattern: video only. The kind above cannot say this — which is
    /// the whole reason ``InputMedia`` exists.
    public let media = InputMedia.video

    /// The master clock (or a synthetic clock under test) whose tick paces
    /// frame synthesis and stamps each frame's PTS.
    private let clock: any EngineClock

    /// The frame width in pixels (kept even — 4:2:0 delivery requires it).
    private let width: Int

    /// The frame height in pixels (kept even — 4:2:0 delivery requires it).
    private let height: Int

    /// Frames synthesized per second; also the timecode's frame base.
    private let frameRate: Int

    /// The wall clock the burned in time of day is read against: `Date.now`,
    /// or a fixed date under test.
    private let wallClock: @Sendable () -> Date

    /// The time zone the time of day is shown in.
    private let timeZone: TimeZone

    /// The event bus, for reporting a synthesis stall and its recovery.
    /// Optional so unit tests construct a generator without one; when absent
    /// the generator simply reports nothing.
    private let eventBus: EventBus?

    /// The shared continuation/task plumbing every consumer's frame stream
    /// runs through.
    private let stream = GeneratorStreamCoordinator<CapturedFrame>()

    /// Creates a bars generator. Defaults match the CLI's program defaults
    /// (1920x1080 at 30 fps, see CLI.md "Compression").
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis and stamps frames.
    ///   - eventBus: The host's event bus, for synthesis diagnostics. Omit it
    ///     where those are not wanted (tests).
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - frameRate: Frames per second.
    ///   - wallClock: The wall clock the burned in time of day is read
    ///     against (default: `Date.now`; tests fix it).
    ///   - timeZone: The time zone the time of day is shown in (default: the
    ///     Mac's own, following a change of zone or daylight saving).
    public init(
        clock: any EngineClock,
        eventBus: EventBus? = nil,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 30,
        wallClock: @escaping @Sendable () -> Date = { Date.now },
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.clock = clock
        self.eventBus = eventBus
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.wallClock = wallClock
        self.timeZone = timeZone
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
        let clock = self.clock
        let wallClock = self.wallClock
        let timeZone = self.timeZone
        return stream.makeStream(
            clock: clock,
            tickInterval: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            inputID: id,
            eventBus: eventBus,
            makeRenderer: { BarsRenderer(width: width, height: height, frameRate: frameRate) },
            render: { (renderer, tickTime) throws(GeneratorSynthesisFailure) in
                let timeOfDay = BarsTimecode.timeOfDay(at: tickTime, clockNow: clock.now, wallNow: wallClock())
                return try renderer.render(at: tickTime, timeOfDay: timeOfDay, in: timeZone)
            }
        )
    }

    /// Finishes every live frame stream. Safe to call more than once.
    public func stop() async {
        await stream.stopAll()
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
    private let pool: GeneratorPixelBufferPool

    /// The timecode font, sized relative to the frame height.
    private let font: CTFont

    /// Creates a renderer and its buffer pool for the given geometry.
    init(width: Int, height: Int, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pool = GeneratorPixelBufferPool(width: width, height: height)
        self.font = CTFontCreateWithName("Menlo-Bold" as CFString, CGFloat(height) / 12, nil)
    }

    /// Renders one frame for the given master clock time, burning in the
    /// time of day it stands for.
    ///
    /// - Parameters:
    ///   - time: The tick's master clock time, the frame's stamp.
    ///   - timeOfDay: The wall-clock moment the tick stands for.
    ///   - timeZone: The time zone the time of day is shown in.
    /// - Throws: A ``GeneratorSynthesisFailure`` if a buffer or drawing
    ///   context could not be created. The caller skips the tick — a
    ///   generator problem must never take down the pipeline — and reports
    ///   the stall.
    func render(at time: CMTime, timeOfDay: Date, in timeZone: TimeZone) throws(GeneratorSynthesisFailure)
        -> CapturedFrame
    {
        let buffer = try pool.buffer()

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try GeneratorPixelBuffer.makeDrawingContext(width: width, height: height, buffer: buffer)

        drawBars(in: context)
        drawTimecode(BarsTimecode.string(for: timeOfDay, frameRate: frameRate, timeZone: timeZone), in: context)
        buffer.tagBT709()
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

}

/// The burned in timecode's formatting, split out from the renderer because
/// it is pure — a moment, a frame base, and a time zone in, a string out,
/// with no buffer, font, or geometry involved — so the clock arithmetic is
/// verifiable without drawing a frame.
enum BarsTimecode {
    /// The `HH:MM:SS:FF` time of day at `date` in `timeZone`: the hours,
    /// minutes, and seconds that zone's clock reads — daylight saving
    /// included, so the hour after a change is the clock's, not elapsed time
    /// since midnight — and the frame within the second at the frame base.
    ///
    /// Time of day since 2026-09-27; until then this formatted the master
    /// clock's own time, wrapping its hours at 24 (the SMPTE 12M convention,
    /// settled 2026-08-06). A time of day never passes 23:59:59, so the wrap
    /// is now the day's.
    ///
    /// - Parameters:
    ///   - date: The moment to show.
    ///   - frameRate: The frame base (frames per second).
    ///   - timeZone: The time zone whose clock to read.
    /// - Returns: The timecode.
    static func string(for date: Date, frameRate: Int, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let fraction = Double(parts.nanosecond ?? 0) / 1_000_000_000
        let frame = max(0, min(frameRate - 1, Int(fraction * Double(frameRate))))
        let components = [parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, frame]
        return components.map { $0.formatted(.number.precision(.integerLength(2...))) }.joined(separator: ":")
    }

    /// The wall-clock moment a master clock time stands for: the wall
    /// clock now, moved by how far `time` is from the master clock now.
    ///
    /// Read per frame rather than fixed once, so a wall clock set or slewed
    /// while the generator runs shows at once. The master clock is not a
    /// time of day — it counts the Mac's awake time since boot — so only
    /// the difference between its two readings is used.
    ///
    /// - Parameters:
    ///   - time: The master clock time to place.
    ///   - clockNow: The master clock now.
    ///   - wallNow: The wall clock now, read beside `clockNow`.
    /// - Returns: The moment `time` stands for.
    static func timeOfDay(at time: CMTime, clockNow: CMTime, wallNow: Date) -> Date {
        wallNow.addingTimeInterval((time - clockNow).seconds)
    }
}
