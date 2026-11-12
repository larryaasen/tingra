//
//  CountdownGenerator.swift
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

/// The countdown video generator: time remaining, drawn as `MM:SS`
/// (`H:MM:SS` from an hour up) on an otherwise transparent frame, so it
/// layers over a camera or a holding picture (docs/PERSONAS.md: a timed
/// deal, the minutes before a show starts, an exercise interval).
///
/// Frames are synthesized on the injected clock's tick — one frame per
/// tick, stamped with the tick's master clock time (CLOCK.md,
/// "Generators") — in the working format: `IOSurface`-backed 32BGRA, SDR,
/// tagged BT.709.
///
/// It counts down to one of two targets, chosen by its **Count To**
/// parameter:
///
/// - **Duration** — hours, minutes, and seconds, measured on the **master
///   clock** (``Stopwatch``), started, paused, and reset through the same
///   State choice the timer has. With **Repeat** on it starts over each
///   time it reaches zero, which is an interval timer.
/// - **Time of Day** — an hour and a minute on the **wall clock**, for "the
///   show starts at 19:00": nothing to start, and right however early the
///   operator opens the project. The target is the next time the clock
///   reads that hour and minute, worked out when the hour, the minute, or
///   the target kind is applied — not on every frame, or the count would
///   reach zero and jump to a day. The wall clock is injected, as the bars
///   generator's is, and each frame shows the time remaining at the
///   wall-clock moment its tick stands for.
///
/// Either way the count holds at `00:00` once it gets there, and shows the
/// remaining time rounded **up** to the second, so it reads the full
/// duration at the start and `00:00` exactly at the end.
///
/// One instance is registered, so its settings are the input's, shared by
/// every layer bound to it.
///
/// A class because the generator owns live stream state (the active frame
/// continuations `stop()` finishes, the settings the renderers read).
public final class CountdownGenerator: Input, Sendable {
    /// The generator's stable input identifier.
    public static let inputID = InputID(rawValue: "countdown")

    /// What a countdown counts to. The raw value is the number the
    /// `target` choice carries in a payload.
    enum Target: Int, CaseIterable, Sendable {
        /// A length of time, started by the operator.
        case duration = 0

        /// The next time the wall clock reads an hour and a minute.
        case timeOfDay = 1

        /// The short user-facing name a host's pop-up menu shows.
        var name: String {
            switch self {
            case .duration: "Duration"
            case .timeOfDay: "Time of Day"
            }
        }
    }

    /// The heading the duration's parameters are grouped under.
    static let durationSection = Target.duration.name

    /// The heading the time of day's parameters are grouped under.
    static let timeOfDaySection = Target.timeOfDay.name

    /// `target`: a duration or a time of day.
    static let targetParameter = Parameter(
        key: "target",
        name: "Count To",
        choices: Target.allCases.map { Parameter.Choice(value: Double($0.rawValue), name: $0.name) },
        defaultValue: Double(Target.duration.rawValue)
    )

    /// `hours`: the duration's whole hours.
    static let hoursParameter = Parameter(key: "hours", name: "Hours", range: 0...23, defaultValue: 0)
        .stepped(by: 1).inSection(durationSection)

    /// `minutes`: the duration's whole minutes, five by default.
    static let minutesParameter = Parameter(key: "minutes", name: "Minutes", range: 0...59, defaultValue: 5)
        .stepped(by: 1).inSection(durationSection)

    /// `seconds`: the duration's whole seconds.
    static let secondsParameter = Parameter(key: "seconds", name: "Seconds", range: 0...59, defaultValue: 0)
        .stepped(by: 1).inSection(durationSection)

    /// `state`: Reset, Running, or Paused — how a duration is started,
    /// paused, and reset.
    static let stateParameter = RunState.parameter.inSection(durationSection)

    /// `repeats`: whether a duration starts over each time it reaches zero.
    static let repeatsParameter = Parameter(key: "repeats", name: "Repeat", defaultIsOn: false)
        .inSection(durationSection)

    /// `targetHour`: the hour of the time of day, on a 24-hour clock.
    static let targetHourParameter = Parameter(key: "targetHour", name: "Hour", range: 0...23, defaultValue: 12)
        .stepped(by: 1).inSection(timeOfDaySection)

    /// `targetMinute`: the minute of the time of day.
    static let targetMinuteParameter = Parameter(key: "targetMinute", name: "Minute", range: 0...59, defaultValue: 0)
        .stepped(by: 1).inSection(timeOfDaySection)

    /// The shared appearance parameters, with a countdown's defaults:
    /// centered, a quarter of the frame tall.
    static let styleParameters = TimeTextStyleParameters(defaultPosition: .center, defaultSizePercent: 25)

    /// The target, the duration and its controls, the time of day, then
    /// the appearance, in display order.
    public var parameters: [Parameter] {
        [
            Self.targetParameter,
            Self.hoursParameter, Self.minutesParameter, Self.secondsParameter,
            Self.stateParameter, Self.repeatsParameter,
            Self.targetHourParameter, Self.targetMinuteParameter,
        ] + Self.styleParameters.all
    }

    /// The stable input identifier (`countdown`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "Countdown"

    /// Generators are their own input kind (see GLOSSARY.md).
    public let kind = InputKind.generator

    /// A picture: video only.
    public let media = InputMedia.video

    /// What the renderers read at every tick, as last applied.
    struct Settings: Sendable, Equatable {
        /// What the countdown counts to.
        var target: Target

        /// The duration, in whole seconds.
        var durationSeconds: Int

        /// Whether a duration starts over at zero.
        var repeats: Bool

        /// The duration's elapsed running time and the state behind it.
        var stopwatch: Stopwatch

        /// The hour of the time of day, `0`…`23`.
        var targetHour: Int

        /// The minute of the time of day, `0`…`59`.
        var targetMinute: Int

        /// The wall-clock moment a time-of-day countdown ends at, resolved
        /// when the hour, the minute, or the target kind was applied; nil
        /// while counting a duration.
        var targetDate: Date?

        /// Where and how the text is drawn.
        var style: TimeTextStyle

        /// The whole seconds remaining at a tick, rounded up, never below
        /// zero.
        ///
        /// - Parameters:
        ///   - tickTime: The tick's master clock time.
        ///   - clockNow: The master clock now.
        ///   - wallNow: The wall clock now, read beside `clockNow`.
        /// - Returns: The seconds the frame for the tick shows.
        func remainingSeconds(at tickTime: CMTime, clockNow: CMTime, wallNow: Date) -> Int {
            let remainingMilliseconds: Int
            switch target {
            case .duration:
                let durationMilliseconds = durationSeconds * 1000
                var elapsed = ClockText.milliseconds(inSeconds: stopwatch.elapsed(at: tickTime).seconds)
                if repeats, durationMilliseconds > 0 {
                    elapsed %= durationMilliseconds
                }
                remainingMilliseconds = durationMilliseconds - elapsed
            case .timeOfDay:
                guard let targetDate else { return 0 }
                let moment = BarsTimecode.timeOfDay(at: tickTime, clockNow: clockNow, wallNow: wallNow)
                remainingMilliseconds = ClockText.milliseconds(inSeconds: targetDate.timeIntervalSince(moment))
            }
            guard remainingMilliseconds > 0 else { return 0 }
            return (remainingMilliseconds + 999) / 1000
        }
    }

    /// The master clock (or a synthetic clock under test) whose tick paces
    /// frame synthesis, stamps each frame's PTS, and measures a duration.
    private let clock: any EngineClock

    /// The frame width in pixels (kept even — 4:2:0 delivery requires it).
    private let width: Int

    /// The frame height in pixels (kept even — 4:2:0 delivery requires it).
    private let height: Int

    /// Frames synthesized per second.
    private let frameRate: Int

    /// The wall clock a time of day is read against: `Date.now`, or a fixed
    /// date under test.
    private let wallClock: @Sendable () -> Date

    /// The time zone a time of day is read in.
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

    /// Creates a countdown generator: five minutes, running from the
    /// clock's current time, until a host applies its parameters. Defaults
    /// match the program defaults (1920x1080 at 30 fps).
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis, stamps frames, and
    ///     measures a duration.
    ///   - eventBus: The host's event bus, for synthesis diagnostics. Omit it
    ///     where those are not wanted (tests).
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - frameRate: Frames per second.
    ///   - wallClock: The wall clock a time of day is read against (default:
    ///     `Date.now`; tests fix it).
    ///   - timeZone: The time zone a time of day is read in (default: the
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
        var initial = Settings(
            target: .duration,
            durationSeconds: 0,
            repeats: false,
            stopwatch: Stopwatch(state: RunState.value(in: [:]), at: clock.now),
            targetHour: 0,
            targetMinute: 0,
            targetDate: nil,
            style: Self.styleParameters.style(in: [:])
        )
        Self.apply([:], to: &initial, clockNow: clock.now, wallNow: wallClock(), timeZone: timeZone)
        self.settings = SharedSetting(initial)
    }

    /// The settings the renderers currently read — what a host's pane
    /// applied, or the declared defaults.
    var currentSettings: Settings { settings.current }

    /// Applies the target, its values, and the appearance from a host's
    /// payload; an omitted key takes its declared default and a number is
    /// clamped to its range. A change of state takes effect at the master
    /// clock's current time, and a time of day is resolved against the wall
    /// clock's; values the countdown already holds change nothing, so
    /// re-applying a payload never restarts the count or moves its target.
    ///
    /// - Parameter parameters: The parameter payload.
    public func setParameters(_ parameters: [String: JSONValue]) async {
        let clockNow = clock.now
        let wallNow = wallClock()
        let timeZone = self.timeZone
        settings.update { settings in
            Self.apply(parameters, to: &settings, clockNow: clockNow, wallNow: wallNow, timeZone: timeZone)
        }
    }

    /// Reads a payload into the settings, moving the stopwatch and
    /// resolving a time of day only where the payload changes them.
    ///
    /// - Parameters:
    ///   - payload: The host's parameter payload.
    ///   - settings: The settings to change.
    ///   - clockNow: The master clock now, when a change of state takes
    ///     effect.
    ///   - wallNow: The wall clock now, which a time of day is the next
    ///     occurrence after.
    ///   - timeZone: The time zone a time of day is read in.
    private static func apply(
        _ payload: [String: JSONValue],
        to settings: inout Settings,
        clockNow: CMTime,
        wallNow: Date,
        timeZone: TimeZone
    ) {
        let targetValue = targetParameter.choice(in: payload)?.value ?? targetParameter.defaultValue
        let target = Target(rawValue: Int(targetValue)) ?? .duration
        let hour = wholeValue(of: targetHourParameter, in: payload)
        let minute = wholeValue(of: targetMinuteParameter, in: payload)

        settings.durationSeconds =
            wholeValue(of: hoursParameter, in: payload) * 3600
            + wholeValue(of: minutesParameter, in: payload) * 60
            + wholeValue(of: secondsParameter, in: payload)
        settings.repeats = repeatsParameter.isOn(in: payload) ?? false
        settings.stopwatch.setState(RunState.value(in: payload), at: clockNow)
        settings.style = styleParameters.style(in: payload)

        switch target {
        case .duration:
            settings.targetDate = nil
        case .timeOfDay:
            let isSameTarget =
                settings.target == .timeOfDay && settings.targetHour == hour && settings.targetMinute == minute
            if !isSameTarget || settings.targetDate == nil {
                settings.targetDate = nextOccurrence(ofHour: hour, minute: minute, after: wallNow, in: timeZone)
            }
        }
        settings.target = target
        settings.targetHour = hour
        settings.targetMinute = minute
    }

    /// A number parameter's value in a payload as a whole number within
    /// its range.
    ///
    /// - Parameters:
    ///   - parameter: The stepped number parameter.
    ///   - payload: The host's parameter payload.
    /// - Returns: The snapped value.
    private static func wholeValue(of parameter: Parameter, in payload: [String: JSONValue]) -> Int {
        let value = parameter.value(in: payload)
        guard value.isFinite else { return Int(parameter.defaultValue) }
        return Int(parameter.snapped(value))
    }

    /// The next moment after `date` at which the zone's clock reads the
    /// hour and minute, on the second — later today, or tomorrow when that
    /// time has already passed. The calendar does the arithmetic, so a
    /// change to or from daylight saving in between is counted correctly.
    ///
    /// - Parameters:
    ///   - hour: The hour, `0`…`23`.
    ///   - minute: The minute, `0`…`59`.
    ///   - date: The moment to look forward from.
    ///   - timeZone: The time zone whose clock to read.
    /// - Returns: The moment, or nil if the calendar finds none.
    static func nextOccurrence(ofHour hour: Int, minute: Int, after date: Date, in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime
        )
    }

    /// The line a frame for a tick shows: the time remaining as of the
    /// tick.
    ///
    /// - Parameter tickTime: The tick's master clock time.
    /// - Returns: The text.
    func text(at tickTime: CMTime) -> String {
        let remaining = settings.current.remainingSeconds(at: tickTime, clockNow: clock.now, wallNow: wallClock())
        return ClockText.string(forSeconds: remaining)
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
