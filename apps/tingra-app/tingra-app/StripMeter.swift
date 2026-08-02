//
//  StripMeter.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraAudio
import TingraPlugInKit

/// A plain, `@MainActor` holder for the latest meter readings: the writer
/// (the ``EngineModel``'s meter drain) and the readers (each strip's
/// ``StripMeter``) share one instance, so the meters render at reading
/// cadence without pushing a mix tick's worth of state changes per block
/// through SwiftUI observation — the ``ProgramFrameRelay`` pattern applied
/// to audio (ARCHITECTURE.md, "Per-strip meters").
@MainActor
final class MeterRelay {
    /// The most recent mix tick's readings, keyed by input id — empty before
    /// the first tick.
    var latest: [InputID: MeterReading] = [:]

    /// The most recent mix tick's **post-fader** master reading — what the
    /// master meter draws (GLOSSARY.md, "Master"). At the floor before the
    /// first tick.
    var master: StereoMeterReading = .floor

    /// Creates an empty relay.
    init() {}
}

/// One channel strip's meter (GLOSSARY.md, "Meter"): a compact capsule
/// beside the strip's controls showing the strip's **pre-fader** signal — an
/// RMS bar over broadcast green/yellow/red zones with a decayed peak
/// marker. Display only: it reports no events and edits nothing; under the
/// app's mute-stops-device policy a muted strip's meter rests at the floor
/// because no samples arrive (app policy, not meter semantics —
/// ARCHITECTURE.md, "Per-strip meters").
///
/// The meter draws in a `TimelineView` sampling the shared ``MeterRelay``
/// each display frame — readings never drive SwiftUI observation, the
/// preview's `MTKView` rule applied to audio display — and applies its
/// ballistics at draw time (``MeterBallistics``).
struct StripMeter: View {
    /// The relay the meter samples.
    let relay: MeterRelay

    /// The strip's input id — the relay key.
    let id: InputID

    /// The meter body: one capsule over the strip's pre-fader reading.
    var body: some View {
        MeterCapsule(height: 6) { relay.latest[id] ?? .floor }
            .frame(width: 72)
            .help(Text("Meter", comment: "Help tag and accessibility label of a channel strip's meter"))
            .accessibilityLabel(
                Text("Meter", comment: "Help tag and accessibility label of a channel strip's meter"))
    }
}

/// The master's meter (GLOSSARY.md, "Master"): two capsules showing the
/// program mix **post-fader** — after every strip's effect chain, level,
/// pan, and mute — one per program channel.
///
/// Stereo where ``StripMeter`` is a single bar, because the master is where
/// the operator judges the stereo image: a hard-panned strip leaving one
/// side dead is exactly what this meter exists to reveal (ARCHITECTURE.md,
/// "The monitor path"). Display only, like the strip meter — no `tap`s,
/// nothing to click.
struct MasterMeter: View {
    /// The relay the meter samples.
    let relay: MeterRelay

    /// The master meter body: the left channel above the right.
    var body: some View {
        VStack(spacing: 3) {
            MeterCapsule(height: 5) { relay.master.left }
            MeterCapsule(height: 5) { relay.master.right }
        }
        .frame(width: 72)
        .help(Text("Master meter", comment: "Help tag and accessibility label of the master's meter"))
        .accessibilityLabel(
            Text("Master meter", comment: "Help tag and accessibility label of the master's meter"))
    }
}

/// One meter capsule: an RMS bar over broadcast green/yellow/red zones with
/// a decayed peak marker, drawn at display cadence.
///
/// Shared by ``StripMeter`` and ``MasterMeter`` so the scale, the zone
/// boundaries, and the ballistics can never drift between the two meters an
/// operator reads side by side. The reading arrives through a closure the
/// capsule calls **inside** its `TimelineView`, so readings never pass
/// through SwiftUI observation — the `MTKView` preview's rule applied to
/// audio display (ARCHITECTURE.md, "Per-strip meters").
struct MeterCapsule: View {
    /// The capsule's height in points.
    let height: CGFloat

    /// The latest reading, sampled once per drawn frame.
    let reading: @MainActor () -> MeterReading

    /// The draw-time ballistics state (a plain class held per view
    /// identity, deliberately unobserved).
    @State private var ballistics = MeterBallistics()

    /// The broadcast zone gradient over the meter's −60…0 dBFS scale:
    /// green through −20 dBFS, yellow through −6, red above — the fill is
    /// masked to the current level, so the zones sit at fixed positions.
    private static let zones = Gradient(stops: [
        .init(color: .green, location: 0),
        .init(color: .green, location: 0.62),
        .init(color: .yellow, location: 0.70),
        .init(color: .yellow, location: 0.87),
        .init(color: .red, location: 0.95),
        .init(color: .red, location: 1),
    ])

    /// The capsule, redrawn at display cadence off the latest reading.
    var body: some View {
        TimelineView(.animation) { timeline in
            let smoothed = ballistics.smoothed(reading(), at: timeline.date)
            Canvas { context, size in
                let track = Path(
                    roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                context.fill(track, with: .style(.quaternary))
                context.clip(to: track)
                if smoothed.rms > 0 {
                    context.fill(
                        Path(CGRect(x: 0, y: 0, width: size.width * smoothed.rms, height: size.height)),
                        with: .linearGradient(
                            Self.zones,
                            startPoint: .zero,
                            endPoint: CGPoint(x: size.width, y: 0)
                        )
                    )
                }
                if smoothed.peak > 0 {
                    let x = min(size.width * smoothed.peak, size.width - 1)
                    context.fill(
                        Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                        with: .style(.primary)
                    )
                }
            }
        }
        .frame(height: height)
    }
}

/// The meter's draw-time ballistics: **instant attack** (a rising signal
/// jumps the display immediately — the operator must never miss a hot
/// block) with a **20 dB per second** decay — between IEC PPM's ~12 dB/s
/// and fast digital meters' ~40 dB/s: brisk enough to track speech, slow
/// enough to read. Ballistics live here, not in the engine, because decay
/// is a display convention — the engine's readings stay raw per-block truth
/// (ARCHITECTURE.md, "Per-strip meters").
@MainActor
final class MeterBallistics {
    /// The displayed RMS level in dBFS (`-.infinity` at the floor).
    private var rms: Double = -.infinity

    /// The displayed peak level in dBFS (`-.infinity` at the floor).
    private var peak: Double = -.infinity

    /// The previous draw's timestamp, so the decay follows real elapsed
    /// time rather than a frame count.
    private var lastDrawn: Date?

    /// The decay rate, in dB per second.
    private static let decayPerSecond: Double = 20

    /// The dBFS level the meter's scale bottoms out at.
    private static let floorDecibels: Double = -60

    /// Creates ballistics resting at the floor.
    init() {}

    /// Advances the decay to `date`, folds in the latest reading (attack is
    /// instant — the reading wins whenever it is louder than the decayed
    /// display), and returns the display fractions on the meter's scale
    /// (`0` at the −60 dBFS floor, `1` at full scale).
    ///
    /// - Parameters:
    ///   - reading: The latest per-block reading from the relay.
    ///   - date: The draw's timestamp.
    /// - Returns: The RMS bar's and the peak marker's fill fractions.
    func smoothed(_ reading: MeterReading, at date: Date) -> (rms: Double, peak: Double) {
        let decay = Self.decayPerSecond * (lastDrawn.map { date.timeIntervalSince($0) } ?? 0)
        lastDrawn = date
        rms = max(Self.decibels(reading.rms), rms - decay)
        peak = max(Self.decibels(reading.peak), peak - decay)
        return (Self.fraction(rms), Self.fraction(peak))
    }

    /// A linear sample magnitude in dBFS (`-.infinity` for silence).
    private static func decibels(_ value: Float) -> Double {
        value > 0 ? 20 * log10(Double(value)) : -.infinity
    }

    /// A dBFS level as a fill fraction of the meter's −60…0 scale, clamped
    /// to `0`...`1`.
    private static func fraction(_ decibels: Double) -> Double {
        min(1, max(0, 1 - decibels / floorDecibels))
    }
}
