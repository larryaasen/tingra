//
//  EffectRegistering.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The registration seam where effect plug-ins attach: the host's effect
/// registry, narrowed to the one thing a plug-in may do with it —
/// contribute effect providers (GLOSSARY.md, "Seam"; ARCHITECTURE.md,
/// "The effect seam").
///
/// Defined here rather than in the host package so a plug-in can register
/// effects without depending on the engine; the host's `EffectRegistry`
/// conforms and arrives through ``PlugInContext/effects``, mirroring
/// ``InputRegistering`` and ``OutputRegistering``.
///
/// One seam, two media protocols: audio and video effects register
/// through the same surface under the same identity model
/// (``EffectID``), but as separate provider kinds — an
/// ``AudioEffectProvider`` processes the mixer's currency, a
/// ``VideoEffectProvider`` the renderer's, and no provider straddles
/// both (the recording-seam precedent).
public protocol EffectRegistering: Sendable {
    /// Registers an audio effect provider contributed by a plug-in.
    ///
    /// Throws a descriptive error if the provider cannot be accepted —
    /// for example, when another audio effect already uses its id.
    func register(_ provider: any AudioEffectProvider) async throws

    /// Registers a video effect provider contributed by a plug-in.
    ///
    /// Throws a descriptive error if the provider cannot be accepted —
    /// for example, when another video effect already uses its id.
    func register(_ provider: any VideoEffectProvider) async throws
}
