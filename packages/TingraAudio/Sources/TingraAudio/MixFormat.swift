//
//  MixFormat.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The program mix's audio geometry: the sample rate the mix runs at and the
/// block size each mix tick produces — the audio counterpart of the video
/// side's `ProgramFormat`.
///
/// The mix is always **stereo float32, deinterleaved** (the platform's
/// standard processing format); only the rate and block size are
/// configurable. Every channel strip's incoming audio is normalized to this
/// format once, at channel intake — the audio mirror of the video rule that
/// conversion happens once, at input normalization (ARCHITECTURE.md, "Color
/// and pixel format conventions").
public struct MixFormat: Sendable, Equatable {
    /// The mix sample rate in hertz.
    public var sampleRate: Double

    /// The number of sample frames each mix tick produces. Together with
    /// ``sampleRate`` this sets the mix tick cadence (1024 frames at
    /// 48 kHz → one block every ~21.3 ms).
    public var blockFrames: Int

    /// Creates a mix format. The defaults — 48 kHz, 1024-frame blocks — are
    /// the delivery rate the streaming path already uses.
    ///
    /// - Parameters:
    ///   - sampleRate: The mix sample rate in hertz.
    ///   - blockFrames: The sample frames per mix block.
    public init(sampleRate: Double = 48_000, blockFrames: Int = 1024) {
        self.sampleRate = sampleRate
        self.blockFrames = blockFrames
    }
}
