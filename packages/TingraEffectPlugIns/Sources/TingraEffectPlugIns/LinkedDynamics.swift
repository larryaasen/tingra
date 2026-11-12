//
//  LinkedDynamics.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// What the three dynamics effects — the limiter, the compressor, and the
/// gate — share: the block walk that turns each sample's level into one
/// gain for every channel, and the decibel and time-constant conversions.
///
/// **Linked** is the point. Each effect computes a single gain per sample
/// from the loudest channel at that sample and applies it to every
/// channel alike, so a stereo strip's image never shifts when one side
/// is louder than the other.
///
/// **No latency.** The effect seam reports none, and a strip's chain is
/// never called for a tick that delivered nothing, so an effect that
/// delayed its signal to look ahead would put the strip out of step with
/// the picture and with every other strip, unannounced. All three
/// effects therefore decide each sample's gain from that sample and the
/// ones before it.
enum LinkedDynamics {
    /// The frames one pass of the walk handles. A chunk's working levels
    /// fit the 1024 bytes a temporary allocation is guaranteed to take
    /// from the stack, so the walk never touches the heap however long
    /// the block is.
    static let chunkFrames = 256

    /// The distance from its target under which an envelope is snapped
    /// onto it, so it settles exactly rather than lingering in denormal
    /// arithmetic.
    ///
    /// The effects carry their envelopes in `Double` for the same reason
    /// they settle: a one-pole step is the remaining distance times
    /// `1 − coefficient`, and near a gain of 1 a `Float` cannot hold a
    /// step that small — with a two-second release the envelope would
    /// stall a few thousandths short of its target and never arrive.
    static let settledEpsilon = 1e-6

    /// Walks the block once, handing `gain` each sample's linked level —
    /// the largest finite absolute sample across the channels at that
    /// frame — in order, and multiplying every channel's sample at that
    /// frame by what it returns.
    ///
    /// A sample that is not finite never raises the level, so one bad
    /// sample cannot poison an effect's envelope. When the channels
    /// differ in length (a contract breach by an earlier effect), only
    /// the frames every channel has are processed. The block's shape is
    /// always preserved.
    ///
    /// - Parameters:
    ///   - channels: The block's samples, channel-major, edited in place.
    ///   - gain: Called once per frame, in order, with the frame's linked
    ///     level; returns the gain to apply to that frame.
    static func apply(to channels: inout [[Float]], gain: (Float) -> Float) {
        guard var frames = channels.first?.count else { return }
        for c in channels.indices {
            frames = min(frames, channels[c].count)
        }
        var start = 0
        while start < frames {
            let count = min(chunkFrames, frames - start)
            withUnsafeTemporaryAllocation(of: Float.self, capacity: count) { levels in
                levels.initialize(repeating: 0)
                for c in channels.indices {
                    channels[c].withUnsafeBufferPointer { source in
                        for i in 0..<count {
                            let magnitude = abs(source[start + i])
                            if magnitude > levels[i], magnitude < .infinity {
                                levels[i] = magnitude
                            }
                        }
                    }
                }
                // The levels become the gains in place: one working
                // buffer, read once and written once per frame.
                for i in 0..<count {
                    levels[i] = gain(levels[i])
                }
                for c in channels.indices {
                    channels[c].withUnsafeMutableBufferPointer { destination in
                        for i in 0..<count {
                            destination[start + i] *= levels[i]
                        }
                    }
                }
            }
            start += count
        }
    }

    /// A level in decibels as a linear factor (`0` dB is `1`).
    ///
    /// - Parameter decibels: The level in decibels.
    static func linear(fromDecibels decibels: Double) -> Float {
        Float(pow(10, decibels / 20))
    }

    /// The one-pole smoothing coefficient for a time constant: the
    /// fraction of the remaining distance to its target an envelope
    /// keeps each sample, so after `milliseconds` it has covered 63 %
    /// (1 − 1/e) of the way. A time or sample rate of zero or less gives
    /// `0` — the envelope reaches its target at once.
    ///
    /// - Parameters:
    ///   - milliseconds: The time constant in milliseconds.
    ///   - sampleRate: The sample rate in hertz.
    static func smoothingCoefficient(milliseconds: Double, sampleRate: Double) -> Double {
        let samples = milliseconds / 1000 * sampleRate
        guard samples > 0 else { return 0 }
        return exp(-1 / samples)
    }
}
