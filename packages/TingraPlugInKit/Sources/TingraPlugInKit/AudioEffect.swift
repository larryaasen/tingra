//
//  AudioEffect.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// One audio processing step in a channel strip's effect chain
/// (GLOSSARY.md, "Channel strip"; ARCHITECTURE.md, "The effect seam").
///
/// The processing signature is the mixer's native currency: blocks of
/// deinterleaved float32 samples at the mix rate, processed in place at
/// the mix tick — never sample buffers, never a format conversion inside
/// the chain. The seam's video counterpart is ``VideoEffect``; the two
/// stay separate protocols so each side's signature stays native and
/// separately evolvable (the recording-seam precedent).
///
/// An instance is per chain slot: the engine asks an
/// ``AudioEffectProvider`` for a fresh instance wherever a chain names the
/// effect, so per-strip processing state (filter memory, envelopes) never
/// leaks between strips. Value semantics carry the state: conformers are
/// typically structs whose mutating `process` advances their own DSP
/// state, and the engine serializes all calls to one instance — a
/// conformer never needs its own locking.
public protocol AudioEffect: Sendable {
    /// Applies a parameter payload — the persisted
    /// ``EffectConfiguration/parameters`` shape — replacing the affected
    /// settings from the next processed block. Keys the payload omits keep
    /// their current values; unknown keys are ignored (a document written
    /// by a newer effect version must not break an older one). Called at
    /// gesture rate while a control drags, so it must be cheap and must
    /// not reset processing state the ear would notice (recompute
    /// coefficients, keep filter memory).
    ///
    /// - Parameter parameters: The parameter values to apply, keyed by
    ///   the effect's declared parameter keys.
    mutating func setParameters(_ parameters: [String: JSONValue])

    /// Processes one block of the strip's audio in place: deinterleaved
    /// float32 samples, one array per source channel (equal lengths, at
    /// least one channel), at the mix rate. Called once per mix tick with
    /// the samples the tick consumed — which can be fewer than a full
    /// block when the strip underruns — and never called for a tick the
    /// strip delivered nothing (v1 effects are processors, not
    /// generators; a tail-emitting effect is a later seam growth). The
    /// effect must preserve the channel count and lengths.
    ///
    /// - Parameters:
    ///   - channels: The block's samples, channel-major, edited in place.
    ///   - sampleRate: The mix sample rate in hertz.
    mutating func process(_ channels: inout [[Float]], sampleRate: Double)
}
