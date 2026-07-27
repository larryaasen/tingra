//
//  MeterReading.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import TingraPlugInKit

/// One channel strip's meter measurement over one mix block (GLOSSARY.md,
/// "Meter"): the strip's signal as delivered, measured **pre-fader** — after
/// intake normalization and the strip's effect chain but before level, pan,
/// and mute — so the reading answers "what is this strip delivering to the
/// fader" (the console's insert-metering point: an effect's gain is visible
/// on the meter) and holds steady while the operator rides the fader
/// (ARCHITECTURE.md, "Per-strip meters", "Audio effect chains").
///
/// Values are linear sample magnitudes (`0` is silence, `1` is full scale; a
/// hot signal can exceed `1`). The dBFS scale, the ballistics, and any color
/// zones are presentation — they belong to the display, not the reading.
public struct MeterReading: Sendable, Equatable {
    /// The largest absolute sample value in the block, across the strip's
    /// source channels — the headroom signal.
    public let peak: Float

    /// The block's root-mean-square — the loudness signal. For a stereo
    /// strip this is the hotter channel's RMS, matching ``peak``'s
    /// max-across-channels rule.
    public let rms: Float

    /// The floor: what a silent or absent signal meters as.
    public static let floor = MeterReading(peak: 0, rms: 0)

    /// Creates a reading.
    ///
    /// - Parameters:
    ///   - peak: The largest absolute sample value in the block.
    ///   - rms: The block's RMS (the hotter channel's, for stereo).
    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }
}

/// The master's meter measurement over one mix block (GLOSSARY.md,
/// "Master"): the program mix measured **post-fader** — after every channel
/// strip's effect chain, level, pan, and mute — one ``MeterReading`` per
/// program channel.
///
/// Stereo where ``MeterReading`` collapses a strip's channels to the hotter
/// one, and deliberately so: the strip meter's max-across-channels rule
/// answers "what is this input delivering", where the master is the one
/// place the operator judges the **stereo image** — a hard-panned strip
/// leaving one side dead is exactly what this reading must show
/// (ARCHITECTURE.md, "The monitor path").
public struct StereoMeterReading: Sendable, Equatable {
    /// The left program channel's reading.
    public let left: MeterReading

    /// The right program channel's reading.
    public let right: MeterReading

    /// The floor: what a silent mix meters as on both channels.
    public static let floor = StereoMeterReading(left: .floor, right: .floor)

    /// Creates a master reading.
    ///
    /// - Parameters:
    ///   - left: The left program channel's reading.
    ///   - right: The right program channel's reading.
    public init(left: MeterReading, right: MeterReading) {
        self.left = left
        self.right = right
    }
}

/// One mix tick's meter readings: every channel strip's ``MeterReading``
/// plus the master's, stamped with the tick's master clock time — tick-paced
/// by construction (CLOCK.md). Delivered on the mixer's single-consumer
/// meter stream (``AudioMixer/meterReadings()``) and never the event bus:
/// per-block data is not control-plane traffic (EVENTS.md).
public struct MeterBlock: Sendable, Equatable {
    /// The mix tick's time on the master clock.
    public let time: CMTime

    /// Each strip's reading this tick, keyed by input id. Every live strip
    /// has an entry — a strip with nothing queued reads
    /// ``MeterReading/floor``, so a consumer sees the floor, never a gap.
    public let strips: [InputID: MeterReading]

    /// The program mix's own reading this tick, measured **post-fader** on
    /// the summed block — the master meter's signal. A tick with nothing
    /// audible reads ``StereoMeterReading/floor``.
    public let master: StereoMeterReading

    /// Creates a meter block.
    ///
    /// - Parameters:
    ///   - time: The mix tick's time on the master clock.
    ///   - strips: Each strip's reading, keyed by input id.
    ///   - master: The program mix's post-fader reading (defaults to the
    ///     floor, so a caller constructing a strips-only block — a test
    ///     fixture — need not state a silent master).
    public init(time: CMTime, strips: [InputID: MeterReading], master: StereoMeterReading = .floor) {
        self.time = time
        self.strips = strips
        self.master = master
    }
}
