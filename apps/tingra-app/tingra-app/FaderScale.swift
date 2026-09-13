//
//  FaderScale.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The mapping between a fader's travel and the linear gain it stands for
/// (GLOSSARY.md, "Fader"): a **breakpoint table linear in decibels between
/// stops** — the taper of a digital console, spreading the range every
/// fader ride happens in (−20…0 dB) over most of the travel and compressing
/// the bottom, where a few points of travel are many decibels nobody rides.
/// Linear-in-dB over the whole travel would put unity at 91 % and squeeze
/// that range into a sliver (ARCHITECTURE.md, "The console mixer").
///
/// Pure and unit-tested. The engine and the document keep **linear gain**
/// — `AudioChannel.level`, `MonitorPreferences.level`, `AudioMixer.setLevel`
/// — so the scale is presentation only: the fader's position and the
/// readout's decibel figure are both derived from the gain, never stored.
nonisolated struct FaderScale: Sendable, Equatable {
    /// One stop of the table: the fader position (`0` at the bottom, `1` at
    /// the top) where the scale reads `decibels`.
    struct Stop: Sendable, Equatable {
        /// The fader position, `0`…`1`.
        let position: Double

        /// The gain in decibels at that position.
        let decibels: Double
    }

    /// The stops, in ascending position — the first at `0`, the last at `1`.
    /// The bottom stop is the quietest gain the fader can express short of
    /// silence; the bottom position itself is silence.
    let stops: [Stop]

    /// The channel strips' scale: silence at the bottom stop, −60 dB a
    /// tenth of the way up, −20 dB at 40 %, **unity three quarters of the
    /// way up**, and **+6 dB at the top** — Logic's ceiling, legal today
    /// because the mixer caps no gain (ARCHITECTURE.md, "The console mixer").
    static let strip = FaderScale(stops: [
        Stop(position: 0, decibels: -72),
        Stop(position: 0.10, decibels: -60),
        Stop(position: 0.25, decibels: -40),
        Stop(position: 0.40, decibels: -20),
        Stop(position: 0.55, decibels: -10),
        Stop(position: 0.75, decibels: 0),
        Stop(position: 1, decibels: 6),
    ])

    /// The monitor fader's scale: the strip table cut at unity and
    /// stretched so **unity is the top**, because the monitor's playback
    /// gain clamps at 1 and a fader whose top quarter did nothing would lie.
    static let monitor = strip.truncated(atDecibels: 0)

    /// The gain in decibels of unity — where a double-click returns a fader.
    static let unityDecibels: Double = 0

    /// The fader position for a linear `gain`: `0` for silence, otherwise
    /// the position whose stop-to-stop interpolation reads the gain's
    /// decibels, clamped to the table's ends — a stored gain quieter than
    /// the bottom stop parks the knob at the stop, and one louder than the
    /// top parks it at the top.
    ///
    /// - Parameter gain: A linear gain, `0` (silence) upward.
    /// - Returns: The fader position, `0`…`1`.
    func position(forGain gain: Double) -> Double {
        guard gain > 0, let first = stops.first, let last = stops.last else { return 0 }
        let decibels = Self.decibels(forGain: gain)
        guard decibels > first.decibels else { return first.position }
        guard decibels < last.decibels else { return last.position }
        for (lower, upper) in zip(stops, stops.dropFirst()) where decibels <= upper.decibels {
            let fraction = (decibels - lower.decibels) / (upper.decibels - lower.decibels)
            return lower.position + fraction * (upper.position - lower.position)
        }
        return last.position
    }

    /// The linear gain a fader `position` stands for: silence at `0`,
    /// otherwise the decibels interpolated between the stops the position
    /// falls between, as a gain.
    ///
    /// - Parameter position: The fader position, `0`…`1` (clamped).
    /// - Returns: The linear gain.
    func gain(forPosition position: Double) -> Double {
        guard position > 0, let last = stops.last else { return 0 }
        guard position < last.position else { return Self.gain(forDecibels: last.decibels) }
        for (lower, upper) in zip(stops, stops.dropFirst()) where position <= upper.position {
            let fraction = (position - lower.position) / (upper.position - lower.position)
            return Self.gain(forDecibels: lower.decibels + fraction * (upper.decibels - lower.decibels))
        }
        return Self.gain(forDecibels: last.decibels)
    }

    /// The fader position of unity on this scale — the double-click reset
    /// target and the detent every fader shares.
    var unityPosition: Double {
        position(forGain: 1)
    }

    /// This scale cut at `decibels` and stretched so that figure sits at
    /// the top: the stops above it are dropped, one is placed exactly there
    /// if none is, and every position is scaled by the cut's position so the
    /// travel still spans `0`…`1`.
    ///
    /// - Parameter decibels: The gain, in decibels, the top of the new scale
    ///   reads.
    /// - Returns: The truncated scale.
    func truncated(atDecibels decibels: Double) -> FaderScale {
        let cut = position(forGain: Self.gain(forDecibels: decibels))
        guard cut > 0 else { return self }
        var kept = stops.filter { $0.position < cut }
        kept.append(Stop(position: cut, decibels: decibels))
        return FaderScale(stops: kept.map { Stop(position: $0.position / cut, decibels: $0.decibels) })
    }

    /// A linear gain in decibels (`-.infinity` for silence).
    static func decibels(forGain gain: Double) -> Double {
        gain > 0 ? 20 * log10(gain) : -.infinity
    }

    /// The linear gain of a figure in decibels.
    static func gain(forDecibels decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    /// A gain's decibel figure as the readout shows it — one decimal with an
    /// explicit sign (`+6.0`, `0.0`, `−12.3`), or nil for silence, which the
    /// readout renders as its own localized `−∞`.
    ///
    /// - Parameter gain: A linear gain.
    /// - Returns: The formatted figure, or nil for silence.
    static func readout(forGain gain: Double) -> String? {
        guard gain > 0 else { return nil }
        // Rounded to the shown decimal first, and a rounded zero made a
        // plain zero, so a gain a hair under unity reads "0.0", never "-0.0".
        let rounded = (decibels(forGain: gain) * 10).rounded() / 10
        let figure = rounded == 0 ? 0 : rounded
        return figure.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
    }
}
