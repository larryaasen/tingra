//
//  TimerGenerator.swift
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

/// The timer video generator: elapsed time counting up from zero, drawn as
/// `MM:SS` (`H:MM:SS` from an hour up) on an otherwise transparent frame,
/// so it layers over a camera (docs/PERSONAS.md, the instructor's "session
/// timer on screen").
///
/// Frames are synthesized on the injected clock's tick — one frame per
/// tick, stamped with the tick's master clock time (CLOCK.md,
/// "Generators") — in the working format: `IOSurface`-backed 32BGRA, SDR,
/// tagged BT.709. **Elapsed time is measured on the master clock**, the
/// difference between a tick's time and the time the timer started
/// (``Stopwatch``), so it is exact under a synthetic clock and never jumps
/// when the wall clock is set.
///
/// It declares its settings as parameters (PLUGINS.md, Decision 15): a
/// **State** choice — Reset, Running, Paused — that is how an operator
/// starts, pauses, and resets it (the kit has no action kind; see
/// ``RunState``), and the shared appearance. The state defaults to Running,
/// so a timer nobody has configured counts from the moment the engine
/// created it. One instance is registered, so its settings are the input's,
/// shared by every layer bound to it.
///
/// A class because the generator owns live stream state (the active frame
/// continuations `stop()` finishes, the settings the renderers read).
public final class TimerGenerator: Input, Sendable {
    /// The generator's stable input identifier.
    public static let inputID = InputID(rawValue: "timer")

    /// The shared appearance parameters, with a timer's defaults: in the
    /// top right corner, a tenth of the frame tall.
    static let styleParameters = TimeTextStyleParameters(defaultPosition: .topRight, defaultSizePercent: 10)

    /// The state, then the appearance, in display order.
    public var parameters: [Parameter] { [RunState.parameter] + Self.styleParameters.all }

    /// The stable input identifier (`timer`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "Timer"

    /// Generators are their own input kind (see GLOSSARY.md).
    public let kind = InputKind.generator

    /// A picture: video only.
    public let media = InputMedia.video

    /// What the renderers read at every tick, as last applied.
    struct Settings: Sendable, Equatable {
        /// The elapsed running time and the state behind it.
        var stopwatch: Stopwatch

        /// Where and how the text is drawn.
        var style: TimeTextStyle
    }

    /// The master clock (or a synthetic clock under test) whose tick paces
    /// frame synthesis, stamps each frame's PTS, and measures elapsed time.
    private let clock: any EngineClock

    /// The frame width in pixels (kept even — 4:2:0 delivery requires it).
    private let width: Int

    /// The frame height in pixels (kept even — 4:2:0 delivery requires it).
    private let height: Int

    /// Frames synthesized per second.
    private let frameRate: Int

    /// The event bus, for reporting a synthesis stall and its recovery.
    /// Optional so unit tests construct a generator without one; when absent
    /// the generator simply reports nothing.
    private let eventBus: EventBus?

    /// The current settings, shared with every live renderer.
    private let settings: SharedSetting<Settings>

    /// The shared continuation/task plumbing every consumer's frame stream
    /// runs through.
    private let stream = GeneratorStreamCoordinator<CapturedFrame>()

    /// Creates a timer generator, running from the clock's current time.
    /// Defaults match the program defaults (1920x1080 at 30 fps).
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis, stamps frames, and
    ///     measures elapsed time.
    ///   - eventBus: The host's event bus, for synthesis diagnostics. Omit it
    ///     where those are not wanted (tests).
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - frameRate: Frames per second.
    public init(
        clock: any EngineClock,
        eventBus: EventBus? = nil,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 30
    ) {
        self.clock = clock
        self.eventBus = eventBus
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.settings = SharedSetting(
            Settings(
                stopwatch: Stopwatch(state: RunState.value(in: [:]), at: clock.now),
                style: Self.styleParameters.style(in: [:])
            )
        )
    }

    /// The settings the renderers currently read — what a host's pane
    /// applied, or the declared defaults.
    var currentSettings: Settings { settings.current }

    /// Applies the state and appearance from a host's payload; an omitted
    /// key takes its declared default. A change of state takes effect at the
    /// master clock's current time; the state the timer already holds
    /// changes nothing, so re-applying a payload never restarts the count.
    ///
    /// - Parameter parameters: The parameter payload.
    public func setParameters(_ parameters: [String: JSONValue]) async {
        let state = RunState.value(in: parameters)
        let style = Self.styleParameters.style(in: parameters)
        let now = clock.now
        settings.update { settings in
            settings.stopwatch.setState(state, at: now)
            settings.style = style
        }
    }

    /// The line a frame for a tick shows: the whole seconds elapsed as of
    /// the tick.
    ///
    /// - Parameter tickTime: The tick's master clock time.
    /// - Returns: The text.
    func text(at tickTime: CMTime) -> String {
        let elapsed = settings.current.stopwatch.elapsed(at: tickTime)
        return ClockText.string(forSeconds: ClockText.milliseconds(inSeconds: elapsed.seconds) / 1000)
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
