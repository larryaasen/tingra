//
//  GateEffect.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// The gate's provider: turns a channel strip down while its signal is
/// under a threshold, so a microphone's room noise is gone between
/// sentences.
public struct GateEffectProvider: AudioEffectProvider {
    /// The gate's stable identifier on the project/scripting contract.
    public static let effectID = EffectID(rawValue: "gate")

    /// The provider's stable identifier.
    public let id = Self.effectID

    /// The user-facing effect name.
    public let name = "Gate"

    /// The five parameters: the level that opens the gate, how far a
    /// closed gate turns the signal down, how fast it opens, how long it
    /// waits before closing, and how fast it closes.
    public var parameters: [Parameter] {
        [
            Parameter(
                key: GateEffect.thresholdKey,
                name: "Threshold",
                range: GateEffect.thresholdRange,
                defaultValue: GateEffect.defaultThreshold,
                unit: "dB"
            ),
            Parameter(
                key: GateEffect.rangeKey,
                name: "Range",
                range: GateEffect.rangeRange,
                defaultValue: GateEffect.defaultRange,
                unit: "dB"
            ),
            Parameter(
                key: GateEffect.attackKey,
                name: "Attack",
                range: GateEffect.attackRange,
                defaultValue: GateEffect.defaultAttack,
                unit: "ms",
                scale: .logarithmic
            ),
            Parameter(
                key: GateEffect.holdKey,
                name: "Hold",
                range: GateEffect.holdRange,
                defaultValue: GateEffect.defaultHold,
                unit: "ms"
            ),
            Parameter(
                key: GateEffect.releaseKey,
                name: "Release",
                range: GateEffect.releaseRange,
                defaultValue: GateEffect.defaultRelease,
                unit: "ms",
                scale: .logarithmic
            ),
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Creates one chain slot's gate at the payload's settings.
    public func makeEffect(parameters: [String: JSONValue]) -> any AudioEffect {
        var effect = GateEffect()
        effect.setParameters(parameters)
        return effect
    }
}

/// A noise gate with no latency. It opens when the signal reaches the
/// threshold and closes once the signal has stayed under a slightly
/// lower level for the hold time; a closed gate turns the signal down by
/// the range. One gain serves every channel (``LinkedDynamics``), so a
/// stereo strip opens and closes as one.
///
/// Three things keep it from chattering. The level it judges is a peak
/// envelope that rises at once and falls over a few milliseconds
/// (``detectorRelease``), so a low note's zero crossings do not read as
/// silence. It closes ``hysteresis`` decibels under where it opens, so a
/// signal hovering at the threshold does not flap it. And the hold time
/// keeps it open across the gaps between words.
///
/// A gate starts closed — the honest state before any signal — and the
/// attack and release times are time constants: the gain covers 63 % of
/// the way to open or closed in that long.
public struct GateEffect: AudioEffect {
    /// The persisted parameter key of the threshold.
    static let thresholdKey = "thresholdDecibels"

    /// The persisted parameter key of the range.
    static let rangeKey = "rangeDecibels"

    /// The persisted parameter key of the attack time.
    static let attackKey = "attackMilliseconds"

    /// The persisted parameter key of the hold time.
    static let holdKey = "holdMilliseconds"

    /// The persisted parameter key of the release time.
    static let releaseKey = "releaseMilliseconds"

    /// The thresholds the effect accepts, in decibels relative to full
    /// scale.
    static let thresholdRange: ClosedRange<Double> = -80...0

    /// The ranges the effect accepts, in decibels: how far a closed gate
    /// turns the signal down. The bottom of the range is silence, not
    /// −80 dB — a gate turned all the way down closes completely.
    static let rangeRange: ClosedRange<Double> = -80...0

    /// The attack times the effect accepts, in milliseconds.
    static let attackRange: ClosedRange<Double> = 1...100

    /// The hold times the effect accepts, in milliseconds.
    static let holdRange: ClosedRange<Double> = 0...2000

    /// The release times the effect accepts, in milliseconds.
    static let releaseRange: ClosedRange<Double> = 10...2000

    /// The default threshold in decibels: over a quiet room, under a
    /// voice.
    static let defaultThreshold: Double = -45

    /// The default range: all the way down, so a closed gate is silent.
    static let defaultRange: Double = -80

    /// The default attack time in milliseconds: fast, so a word's first
    /// consonant is not lost.
    static let defaultAttack: Double = 2

    /// The default hold time in milliseconds.
    static let defaultHold: Double = 100

    /// The default release time in milliseconds.
    static let defaultRelease: Double = 200

    /// How far under the opening threshold the gate closes, in decibels.
    static let hysteresis: Double = 3

    /// The time constant, in milliseconds, the detector's peak envelope
    /// falls with.
    static let detectorRelease: Double = 10

    /// The level under which the detector's envelope is snapped to zero,
    /// far below the lowest threshold, so it never lingers in denormal
    /// arithmetic.
    private static let detectorFloor: Float = 1e-9

    /// The linear level at or over which the gate opens.
    private var openLevel = LinkedDynamics.linear(fromDecibels: GateEffect.defaultThreshold)

    /// The linear level under which an open gate starts to close.
    private var closeLevel = LinkedDynamics.linear(fromDecibels: GateEffect.defaultThreshold - GateEffect.hysteresis)

    /// The gain of a closed gate (`0` at the bottom of the range).
    private var floorGain: Double = 0

    /// The attack time constant in milliseconds.
    private var attack = GateEffect.defaultAttack

    /// The hold time in milliseconds.
    private var hold = GateEffect.defaultHold

    /// The release time constant in milliseconds.
    private var release = GateEffect.defaultRelease

    /// The sample rate the coefficients and the hold length were last
    /// computed at, or nil when they must be recomputed at the next
    /// block.
    private var computedForSampleRate: Double?

    /// The fraction of its distance to open the gain keeps each sample.
    private var attackCoefficient: Double = 0

    /// The fraction of its distance to closed the gain keeps each sample.
    private var releaseCoefficient: Double = 0

    /// The fraction of itself the detector's envelope keeps each sample
    /// while the signal is under it.
    private var detectorCoefficient: Float = 0

    /// The hold time in samples.
    private var holdSamples = 0

    /// The sample rate ``holdSamples`` and ``holdRemaining`` count at, kept
    /// apart from ``computedForSampleRate`` (which a parameter change
    /// clears) so a hold already running can be carried into a new hold
    /// length or a new rate by how long it has run.
    private var holdSampleRate: Double = 0

    /// The detector's peak envelope — carried from one block to the next.
    private var detector: Float = 0

    /// Whether the gate is open — carried from one block to the next.
    private var isOpen = false

    /// The samples of hold left before an open gate under its closing
    /// level closes — carried from one block to the next.
    private var holdRemaining = 0

    /// The gain the gate is applying right now — carried from one block
    /// to the next. A gate starts closed, at its floor (``hasStarted``).
    private var gain: Double = 0

    /// Whether the gate has processed a block. The first block starts the
    /// gain at the closed gate's floor as configured by then, so a gate
    /// with a range above the bottom does not fade in from silence — at a
    /// range of 0 dB it passes every sample untouched from the first.
    private var hasStarted = false

    /// Creates the gate at its default settings, closed.
    public init() {}

    /// Reads new settings from the payload, each clamped to its declared
    /// range; an absent or non-numeric key keeps the current value.
    /// Whether the gate is open and its current gain are kept, so a drag
    /// never clicks.
    public mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let decibels = parameters[Self.thresholdKey]?.doubleValue {
            let threshold = Self.thresholdRange.clamping(decibels)
            openLevel = LinkedDynamics.linear(fromDecibels: threshold)
            closeLevel = LinkedDynamics.linear(fromDecibels: threshold - Self.hysteresis)
        }
        if let decibels = parameters[Self.rangeKey]?.doubleValue {
            let range = Self.rangeRange.clamping(decibels)
            floorGain = range <= Self.rangeRange.lowerBound ? 0 : pow(10, range / 20)
        }
        if let milliseconds = parameters[Self.attackKey]?.doubleValue {
            attack = Self.attackRange.clamping(milliseconds)
            computedForSampleRate = nil
        }
        if let milliseconds = parameters[Self.holdKey]?.doubleValue {
            hold = Self.holdRange.clamping(milliseconds)
            computedForSampleRate = nil
        }
        if let milliseconds = parameters[Self.releaseKey]?.doubleValue {
            release = Self.releaseRange.clamping(milliseconds)
            computedForSampleRate = nil
        }
    }

    /// Gates the block in place. A sample rate of zero or less still
    /// gates — with no hold, and the gain moving at once.
    public mutating func process(_ channels: inout [[Float]], sampleRate: Double) {
        if computedForSampleRate != sampleRate {
            attackCoefficient = LinkedDynamics.smoothingCoefficient(milliseconds: attack, sampleRate: sampleRate)
            releaseCoefficient = LinkedDynamics.smoothingCoefficient(milliseconds: release, sampleRate: sampleRate)
            detectorCoefficient = Float(
                LinkedDynamics.smoothingCoefficient(milliseconds: Self.detectorRelease, sampleRate: sampleRate))
            // A new hold length applies to a hold already running by how
            // long it has run: what is left is the new length less the time
            // already held, so a hold shortened to under that closes at once.
            let heldSamples = Double(max(0, holdSamples - holdRemaining))
            let heldSeconds = holdSampleRate > 0 ? heldSamples / holdSampleRate : 0
            holdSamples = sampleRate > 0 ? Int((hold / 1000 * sampleRate).rounded()) : 0
            holdRemaining = max(0, holdSamples - Int((heldSeconds * max(0, sampleRate)).rounded()))
            holdSampleRate = sampleRate
            computedForSampleRate = sampleRate
        }
        if !hasStarted {
            gain = floorGain
            hasStarted = true
        }
        var state = self
        LinkedDynamics.apply(to: &channels) { level in
            let decayed = state.detector * state.detectorCoefficient
            state.detector = level > decayed ? level : (decayed < Self.detectorFloor ? 0 : decayed)
            if state.detector >= state.openLevel {
                state.isOpen = true
                state.holdRemaining = state.holdSamples
            } else if state.isOpen {
                if state.detector >= state.closeLevel {
                    // Between the two levels an open gate stays open and
                    // the hold has not started.
                    state.holdRemaining = state.holdSamples
                } else if state.holdRemaining > 0 {
                    state.holdRemaining -= 1
                } else {
                    state.isOpen = false
                }
            }
            let target = state.isOpen ? 1 : state.floorGain
            let coefficient = target > state.gain ? state.attackCoefficient : state.releaseCoefficient
            state.gain = target + (state.gain - target) * coefficient
            if abs(state.gain - target) < LinkedDynamics.settledEpsilon {
                state.gain = target
            }
            return Float(state.gain)
        }
        self = state
    }
}
