//
//  Stopwatch.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import TingraPlugInKit

/// What the operator has asked a timer or a countdown to do. The raw value
/// is the number a ``Parameter/Kind/choice`` payload carries, so it is part
/// of the project contract and never renumbered.
///
/// A choice rather than buttons because the plug-in kit's parameter kinds
/// are number, color, toggle, and choice — there is no action kind — and
/// three named states say start, pause, and reset honestly: pick Reset to
/// return to the start and hold there, Running to count, Paused to hold
/// where it is.
enum RunState: Int, CaseIterable, Sendable {
    /// Held at the start: zero elapsed.
    case reset = 0

    /// Counting.
    case running = 1

    /// Held where it was when paused.
    case paused = 2

    /// The short user-facing name a host's pop-up menu shows.
    var name: String {
        switch self {
        case .reset: "Reset"
        case .running: "Running"
        case .paused: "Paused"
        }
    }

    /// The declared `state` parameter, defaulting to ``running`` so a
    /// generator nobody has configured — an agent's, say — counts from the
    /// moment the engine created it.
    static let parameter = Parameter(
        key: "state",
        name: "State",
        choices: allCases.map { Parameter.Choice(value: Double($0.rawValue), name: $0.name) },
        defaultValue: Double(running.rawValue)
    )

    /// Reads the state out of a payload; an omitted key or a value no case
    /// has is ``running``, the declared default.
    ///
    /// - Parameter payload: The host's parameter payload.
    /// - Returns: The state the payload asks for.
    static func value(in payload: [String: JSONValue]) -> RunState {
        let value = parameter.choice(in: payload)?.value ?? parameter.defaultValue
        return RunState(rawValue: Int(value)) ?? .running
    }
}

/// Elapsed running time on the master clock: the arithmetic behind the
/// timer and the countdown's duration (CLOCK.md, "Generators").
///
/// Pure — master clock times in, a duration out — so start, pause, resume,
/// and reset are verifiable with no stream and no frame. It never reads a
/// clock itself: the generator hands it the master clock's `now` when the
/// state changes and each tick's time when a frame is drawn, so a synthetic
/// clock drives it exactly.
struct Stopwatch: Sendable, Equatable {
    /// The state last applied.
    private(set) var state: RunState

    /// The running time banked by earlier stretches, up to the last pause.
    private var accumulated: CMTime = .zero

    /// The master clock time the current stretch began at, or nil while
    /// not running.
    private var runningSince: CMTime?

    /// Creates a stopwatch in a state, as of a master clock time.
    ///
    /// - Parameters:
    ///   - state: The first state.
    ///   - now: The master clock time it takes effect at.
    init(state: RunState, at now: CMTime) {
        self.state = state
        if state == .running {
            runningSince = now
        }
    }

    /// Moves to a state as of a master clock time. Applying the state it
    /// already holds changes nothing, so a host that sends the whole
    /// payload again — on every edit of another parameter — never restarts
    /// or nudges the count.
    ///
    /// - Parameters:
    ///   - newState: The state to move to.
    ///   - now: The master clock time the change takes effect at.
    mutating func setState(_ newState: RunState, at now: CMTime) {
        guard newState != state else { return }
        switch newState {
        case .reset:
            accumulated = .zero
            runningSince = nil
        case .running:
            runningSince = now
        case .paused:
            accumulated = elapsed(at: now)
            runningSince = nil
        }
        state = newState
    }

    /// The running time as of a master clock time: what earlier stretches
    /// banked plus the current stretch. A time before the current stretch
    /// began adds nothing, never a negative amount.
    ///
    /// - Parameter time: The master clock time to measure at.
    /// - Returns: The elapsed running time, never negative.
    func elapsed(at time: CMTime) -> CMTime {
        guard let runningSince, time > runningSince else { return accumulated }
        return accumulated + (time - runningSince)
    }
}

/// The digits a timer or a countdown shows, split out because it is pure:
/// whole seconds in, a string out, with no clock, buffer, or font involved.
enum ClockText {
    /// `MM:SS` below an hour and `H:MM:SS` from an hour up. The digits are
    /// ASCII whatever the Mac's locale, since the picture is burned into a
    /// program that viewers anywhere read.
    ///
    /// - Parameter seconds: Whole seconds; a negative count reads as zero.
    /// - Returns: The text.
    static func string(forSeconds seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        guard hours > 0 else { return "\(twoDigits(minutes)):\(twoDigits(remainder))" }
        return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))"
    }

    /// A non-negative number as at least two ASCII digits.
    ///
    /// - Parameter number: The number.
    /// - Returns: The number, with a leading zero below ten.
    static func twoDigits(_ number: Int) -> String {
        number < 10 ? "0\(number)" : "\(number)"
    }

    /// A duration in whole milliseconds, the unit the timer and countdown
    /// round in, so a tick that lands a hair before a second boundary in
    /// floating point still reads as on it.
    ///
    /// - Parameter seconds: The duration in seconds.
    /// - Returns: Its length in milliseconds, rounded to the nearest; zero
    ///   for a duration that is not finite or too long to count (tens of
    ///   thousands of years), so the conversion can never trap.
    static func milliseconds(inSeconds seconds: Double) -> Int {
        guard seconds.isFinite, abs(seconds) < 1e12 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}
