//
//  VideoEffect.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage

/// One video processing step in a layer's effect chain (GLOSSARY.md,
/// "Effect"; ARCHITECTURE.md, "The effect seam").
///
/// The processing signature is the renderer's native currency: a lazy,
/// GPU-resident `CIImage` in, a `CIImage` out — the only currency that
/// lets the renderer fuse a whole chain into one render pass, where
/// per-effect pixel-buffer hand-offs would materialize an intermediate
/// buffer per effect per layer per tick and defeat the GPU-resident rule.
/// Core Image enters the protocol package the way Core Video already did
/// (`CapturedFrame` wraps `CVPixelBuffer`): an Apple media framework as
/// seam currency, not a third-party dependency. The seam's audio
/// counterpart is ``AudioEffect``; the two stay separate protocols so
/// each side's signature stays native and separately evolvable.
///
/// An instance is per chain slot, created by a ``VideoEffectProvider``;
/// the engine serializes all calls to one instance, so a conformer never
/// needs its own locking. A custom Metal kernel inside an effect is the
/// effect's own business — for third parties, running their *code* is the
/// external-bundle-loader boundary, not a new one (the shader-transition
/// security posture stands unchanged).
public protocol VideoEffect: Sendable {
    /// Applies a parameter payload — the persisted
    /// ``EffectConfiguration/parameters`` shape — affecting every frame
    /// processed after it. Keys the payload omits keep their current
    /// values; unknown keys are ignored. Called at gesture rate while a
    /// control drags, so it must be cheap.
    ///
    /// - Parameter parameters: The parameter values to apply, keyed by
    ///   the effect's declared parameter keys.
    mutating func setParameters(_ parameters: [String: JSONValue])

    /// Processes one frame's image, returning the processed image —
    /// typically a lazily composed Core Image filter graph over the
    /// input, which the renderer fuses into its one render pass. Called
    /// once per program tick for the layer the chain belongs to. A
    /// conformer that cannot process a frame returns the input unchanged
    /// — a chain degrades to pass-through, never a black layer and never
    /// a crash (the never-crash rule).
    ///
    /// - Parameter image: The layer's image before this effect.
    /// - Returns: The image after this effect.
    mutating func process(_ image: CIImage) -> CIImage
}
