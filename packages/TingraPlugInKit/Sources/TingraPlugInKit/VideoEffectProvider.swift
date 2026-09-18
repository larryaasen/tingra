//
//  VideoEffectProvider.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// What an effect plug-in registers for a video effect: a factory
/// declaring the effect's identity and parameters and creating a fresh
/// ``VideoEffect`` instance per chain slot — the audio side's
/// ``AudioEffectProvider``, for the video media protocol
/// (ARCHITECTURE.md, "The effect seam"). Its declared parameters come from
/// ``ParameterDescribing``, like every registration's.
public protocol VideoEffectProvider: ParameterDescribing {
    /// The effect's stable identifier — what a persisted chain names
    /// (``EffectConfiguration/effect``).
    var id: EffectID { get }

    /// A short user-facing name, e.g. "Blur".
    var name: String { get }

    /// Creates one chain slot's effect instance, configured with the
    /// slot's persisted parameter payload (keys the payload omits take
    /// their declared defaults).
    ///
    /// - Parameter parameters: The slot's parameter payload.
    /// - Returns: A fresh effect instance; the engine owns its lifecycle.
    func makeEffect(parameters: [String: JSONValue]) -> any VideoEffect
}
