//
//  AudioEffectProvider.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// What an effect plug-in registers for an audio effect: a factory
/// declaring the effect's identity and parameters and creating a fresh
/// ``AudioEffect`` instance per chain slot — the provider/instance split
/// of the output seam (`StreamingServiceProvider`/`StreamingService`)
/// applied to effects (ARCHITECTURE.md, "The effect seam").
///
/// An effect instance carries per-slot processing state (filter memory,
/// envelopes), so the registry holds providers and the engine asks the
/// provider for a new instance wherever a chain names its ``id``.
public protocol AudioEffectProvider: Sendable {
    /// The effect's stable identifier — what a persisted chain names
    /// (``EffectConfiguration/effect``).
    var id: EffectID { get }

    /// A short user-facing name, e.g. "Gain".
    var name: String { get }

    /// The parameters the effect declares, in display order — what a host
    /// UI draws controls from and what the persisted payload's keys mean.
    var parameters: [EffectParameter] { get }

    /// Creates one chain slot's effect instance, configured with the
    /// slot's persisted parameter payload (keys the payload omits take
    /// their declared defaults).
    ///
    /// - Parameter parameters: The slot's parameter payload.
    /// - Returns: A fresh effect instance; the engine owns its lifecycle.
    func makeEffect(parameters: [String: JSONValue]) -> any AudioEffect
}
