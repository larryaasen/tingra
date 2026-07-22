//
//  BiquadFilter.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A second-order (biquad) IIR filter shared by the high- and low-pass
/// effects: Robert Bristow-Johnson's audio-EQ-cookbook coefficients at
/// Butterworth Q (1/√2), processed per channel in direct form I.
///
/// The filter owns everything the two effects share — coefficient
/// computation, lazily recomputed when the cutoff or sample rate changes,
/// and per-channel filter memory, resized when the strip's channel count
/// changes (a device format change resets the memory; a parameter change
/// never does, so a cutoff sweep stays click-free).
struct BiquadFilter {
    /// The filter responses the biquad can take.
    enum Kind {
        /// Attenuates below the cutoff — the rumble filter.
        case highPass

        /// Attenuates above the cutoff — the darkening filter.
        case lowPass
    }

    /// The response this instance computes coefficients for.
    private let kind: Kind

    /// The cutoff frequency in hertz the coefficients are computed for.
    private var cutoff: Double

    /// The sample rate the coefficients were last computed at, or nil
    /// before the first block.
    private var computedForSampleRate: Double?

    /// The normalized feed-forward coefficients.
    private var b0: Float = 1
    /// The normalized feed-forward coefficient one sample back.
    private var b1: Float = 0
    /// The normalized feed-forward coefficient two samples back.
    private var b2: Float = 0
    /// The normalized feedback coefficient one sample back.
    private var a1: Float = 0
    /// The normalized feedback coefficient two samples back.
    private var a2: Float = 0

    /// Each channel's filter memory: the previous two inputs and outputs.
    private var memory: [(x1: Float, x2: Float, y1: Float, y2: Float)] = []

    /// Creates a filter.
    ///
    /// - Parameters:
    ///   - kind: The filter response.
    ///   - cutoff: The initial cutoff frequency in hertz.
    init(kind: Kind, cutoff: Double) {
        self.kind = kind
        self.cutoff = cutoff
    }

    /// Sets the cutoff frequency. Coefficients recompute at the next
    /// block; filter memory is kept, so a sweep stays click-free.
    ///
    /// - Parameter cutoff: The new cutoff frequency in hertz.
    mutating func setCutoff(_ cutoff: Double) {
        guard cutoff != self.cutoff else { return }
        self.cutoff = cutoff
        computedForSampleRate = nil
    }

    /// Filters every channel of the block in place.
    ///
    /// - Parameters:
    ///   - channels: The block's samples, channel-major, edited in place.
    ///   - sampleRate: The block's sample rate in hertz.
    mutating func process(_ channels: inout [[Float]], sampleRate: Double) {
        guard sampleRate > 0 else { return }
        if computedForSampleRate != sampleRate {
            computeCoefficients(sampleRate: sampleRate)
        }
        if memory.count != channels.count {
            // A channel-count change is a new signal topology: fresh memory.
            memory = Array(repeating: (0, 0, 0, 0), count: channels.count)
        }
        for c in channels.indices {
            var (x1, x2, y1, y2) = memory[c]
            for i in channels[c].indices {
                let x0 = channels[c][i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                channels[c][i] = y0
                x2 = x1
                x1 = x0
                y2 = y1
                y1 = y0
            }
            memory[c] = (x1, x2, y1, y2)
        }
    }

    /// Computes the cookbook coefficients for the current cutoff at the
    /// given sample rate, at Butterworth Q, normalized by `a0`. The cutoff
    /// is capped just under Nyquist so an out-of-band value stays stable
    /// rather than folding.
    ///
    /// - Parameter sampleRate: The sample rate in hertz.
    private mutating func computeCoefficients(sampleRate: Double) {
        let nyquistSafeCutoff = min(cutoff, sampleRate * 0.49)
        let w0 = 2 * Double.pi * nyquistSafeCutoff / sampleRate
        let cosw0 = cos(w0)
        // alpha = sin(w0) / (2Q) at Butterworth Q = 1/√2, so 2Q = √2.
        let alpha = sin(w0) / 2.0.squareRoot()

        let a0 = 1 + alpha
        switch kind {
        case .highPass:
            b0 = Float((1 + cosw0) / 2 / a0)
            b1 = Float(-(1 + cosw0) / a0)
            b2 = Float((1 + cosw0) / 2 / a0)
        case .lowPass:
            b0 = Float((1 - cosw0) / 2 / a0)
            b1 = Float((1 - cosw0) / a0)
            b2 = Float((1 - cosw0) / 2 / a0)
        }
        a1 = Float(-2 * cosw0 / a0)
        a2 = Float((1 - alpha) / a0)
        computedForSampleRate = sampleRate
    }
}
