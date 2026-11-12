//
//  TimeStampGenerator.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import TingraEventBus
import TingraPlugInKit

/// The time stamp video generator: the local date and time of day, drawn
/// as one line on an otherwise transparent frame, so it layers over a
/// camera the way a text file does (docs/PERSONAS.md, the set-and-forget
/// camera's "date and time stamp on the picture").
///
/// Frames are synthesized on the injected clock's tick — one frame per
/// tick, stamped with the tick's master clock time (CLOCK.md,
/// "Generators") — in the working format: `IOSurface`-backed 32BGRA, SDR,
/// tagged BT.709. **The time shown is the wall clock's, never the master
/// clock's**: the master clock counts the Mac's awake time since boot and
/// cannot say what time of day it is, so each frame shows the wall-clock
/// moment its tick stands for, read through an injected wall clock exactly
/// as the bars generator's timecode is. Under a synthetic clock and a fixed
/// wall clock the generator is fully deterministic.
///
/// It declares its settings as parameters (PLUGINS.md, Decision 15) —
/// whether the date and the seconds show, a 12- or 24-hour clock, and the
/// shared appearance (position, size, color, background) — which a host
/// draws a settings pane from and applies live through
/// ``setParameters(_:)``. One instance is registered, so its settings are
/// the input's, shared by every layer bound to it.
///
/// A class because the generator owns live stream state (the active frame
/// continuations `stop()` finishes, the settings the renderers read).
public final class TimeStampGenerator: Input, Sendable {
    /// The generator's stable input identifier.
    public static let inputID = InputID(rawValue: "time-stamp")

    /// `showsDate`: whether the date is drawn before the time.
    static let showsDateParameter = Parameter(key: "showsDate", name: "Date", defaultIsOn: true)

    /// `showsSeconds`: whether the time carries its seconds.
    static let showsSecondsParameter = Parameter(key: "showsSeconds", name: "Seconds", defaultIsOn: true)

    /// `twelveHour`: a 12-hour clock with AM and PM instead of a 24-hour
    /// one.
    static let twelveHourParameter = Parameter(key: "twelveHour", name: "12-Hour Clock", defaultIsOn: false)

    /// The shared appearance parameters, with a time stamp's defaults:
    /// small, in the bottom right corner.
    static let styleParameters = TimeTextStyleParameters(defaultPosition: .bottomRight, defaultSizePercent: 5)

    /// The format toggles, then the appearance, in display order.
    public var parameters: [Parameter] {
        [Self.showsDateParameter, Self.showsSecondsParameter, Self.twelveHourParameter] + Self.styleParameters.all
    }

    /// The stable input identifier (`time-stamp`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "Time Stamp"

    /// Generators are their own input kind (see GLOSSARY.md).
    public let kind = InputKind.generator

    /// A picture: video only.
    public let media = InputMedia.video

    /// What the renderers read at every tick, as last applied.
    struct Settings: Sendable, Equatable {
        /// Which parts of the moment the text carries.
        var format: TimeStampFormat

        /// Where and how the text is drawn.
        var style: TimeTextStyle
    }

    /// The master clock (or a synthetic clock under test) whose tick paces
    /// frame synthesis and stamps each frame's PTS.
    private let clock: any EngineClock

    /// The frame width in pixels (kept even — 4:2:0 delivery requires it).
    private let width: Int

    /// The frame height in pixels (kept even — 4:2:0 delivery requires it).
    private let height: Int

    /// Frames synthesized per second.
    private let frameRate: Int

    /// The wall clock the date and time are read against: `Date.now`, or a
    /// fixed date under test.
    private let wallClock: @Sendable () -> Date

    /// The time zone the date and time are shown in.
    private let timeZone: TimeZone

    /// The event bus, for reporting a synthesis stall and its recovery.
    /// Optional so unit tests construct a generator without one; when absent
    /// the generator simply reports nothing.
    private let eventBus: EventBus?

    /// The current settings, shared with every live renderer.
    private let settings: SharedSetting<Settings>

    /// The shared continuation/task plumbing every consumer's frame stream
    /// runs through.
    private let stream = GeneratorStreamCoordinator<CapturedFrame>()

    /// Creates a time stamp generator. Defaults match the program defaults
    /// (1920x1080 at 30 fps).
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis and stamps frames.
    ///   - eventBus: The host's event bus, for synthesis diagnostics. Omit it
    ///     where those are not wanted (tests).
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - frameRate: Frames per second.
    ///   - wallClock: The wall clock the date and time are read against
    ///     (default: `Date.now`; tests fix it).
    ///   - timeZone: The time zone the date and time are shown in (default:
    ///     the Mac's own, following a change of zone or daylight saving).
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
        self.settings = SharedSetting(Self.settings(in: [:]))
    }

    /// The settings the renderers currently read — what a host's pane
    /// applied, or the declared defaults.
    var currentSettings: Settings { settings.current }

    /// Applies the format and appearance from a host's payload; an omitted
    /// key takes its declared default. Takes effect at every live stream's
    /// next frame.
    ///
    /// - Parameter parameters: The parameter payload.
    public func setParameters(_ parameters: [String: JSONValue]) async {
        let applied = Self.settings(in: parameters)
        settings.update { $0 = applied }
    }

    /// Reads the settings out of a payload.
    ///
    /// - Parameter payload: The host's parameter payload.
    /// - Returns: The settings it describes, defaults filled in.
    private static func settings(in payload: [String: JSONValue]) -> Settings {
        Settings(
            format: TimeStampFormat(
                showsDate: showsDateParameter.isOn(in: payload) ?? true,
                showsSeconds: showsSecondsParameter.isOn(in: payload) ?? true,
                usesTwelveHourClock: twelveHourParameter.isOn(in: payload) ?? false
            ),
            style: styleParameters.style(in: payload)
        )
    }

    /// The line a frame for a tick shows: the wall-clock moment the tick
    /// stands for, in the generator's time zone and current format.
    ///
    /// - Parameter tickTime: The tick's master clock time.
    /// - Returns: The text.
    func text(at tickTime: CMTime) -> String {
        let moment = BarsTimecode.timeOfDay(at: tickTime, clockNow: clock.now, wallNow: wallClock())
        return settings.current.format.string(for: moment, timeZone: timeZone)
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
        let settings = self.settings
        return stream.makeStream(
            clock: clock,
            tickInterval: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            inputID: id,
            eventBus: eventBus,
            makeRenderer: { TimeTextRenderer(width: width, height: height) },
            render: { [self] (renderer, tickTime) throws(GeneratorSynthesisFailure) in
                try renderer.render(text(at: tickTime), style: settings.current.style, at: tickTime)
            }
        )
    }

    /// Finishes every live frame stream. Safe to call more than once.
    public func stop() async {
        await stream.stopAll()
    }
}

/// Which parts of a moment a time stamp carries, and the text for one —
/// split out from the generator because it is pure: a moment and a time
/// zone in, a string out, so the clock arithmetic is verifiable without
/// drawing a frame.
struct TimeStampFormat: Sendable, Equatable {
    /// Whether the date is written before the time.
    var showsDate: Bool

    /// Whether the time carries its seconds.
    var showsSeconds: Bool

    /// Whether the time is on a 12-hour clock with AM and PM.
    var usesTwelveHourClock: Bool

    /// The text for a moment: `2026-11-11 14:05:09` in full, the date
    /// dropped or the seconds dropped as the format says, `2:05:09 PM` on
    /// a 12-hour clock.
    ///
    /// The date is year-month-day in ASCII digits whatever the Mac's
    /// locale: a stamp burned into a recording is read later, elsewhere,
    /// and that order is the one no reader mistakes for another. The hours,
    /// minutes, and seconds are the ones the zone's clock reads, daylight
    /// saving included.
    ///
    /// - Parameters:
    ///   - date: The moment to show.
    ///   - timeZone: The time zone whose calendar and clock to read.
    /// - Returns: The text.
    func string(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour = parts.hour ?? 0

        var time: String
        if usesTwelveHourClock {
            // 0 and 12 both read as 12 on a 12-hour clock.
            let twelveHour = hour % 12 == 0 ? 12 : hour % 12
            time = "\(twelveHour):\(ClockText.twoDigits(parts.minute ?? 0))"
        } else {
            time = "\(ClockText.twoDigits(hour)):\(ClockText.twoDigits(parts.minute ?? 0))"
        }
        if showsSeconds {
            time += ":\(ClockText.twoDigits(parts.second ?? 0))"
        }
        if usesTwelveHourClock {
            time += hour < 12 ? " AM" : " PM"
        }
        guard showsDate else { return time }

        let year = parts.year ?? 0
        let day = "\(year)-\(ClockText.twoDigits(parts.month ?? 0))-\(ClockText.twoDigits(parts.day ?? 0))"
        return "\(day) \(time)"
    }
}
