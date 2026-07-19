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
/// intake normalization but before level, pan, and mute — so the reading
/// answers "what is this input delivering" and holds steady while the
/// operator rides the fader (ARCHITECTURE.md, "Per-strip meters").
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

/// One mix tick's meter readings: every channel strip's ``MeterReading``,
/// stamped with the tick's master clock time — tick-paced by construction
/// (CLOCK.md). Delivered on the mixer's single-consumer meter stream
/// (``AudioMixer/meterReadings()``) and never the event bus: per-block data
/// is not control-plane traffic (EVENTS.md).
public struct MeterBlock: Sendable, Equatable {
    /// The mix tick's time on the master clock.
    public let time: CMTime

    /// Each strip's reading this tick, keyed by input id. Every live strip
    /// has an entry — a strip with nothing queued reads
    /// ``MeterReading/floor``, so a consumer sees the floor, never a gap.
    public let strips: [InputID: MeterReading]

    /// Creates a meter block.
    ///
    /// - Parameters:
    ///   - time: The mix tick's time on the master clock.
    ///   - strips: Each strip's reading, keyed by input id.
    public init(time: CMTime, strips: [InputID: MeterReading]) {
        self.time = time
        self.strips = strips
    }
}
