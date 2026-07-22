//
//  EffectPlugIn.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The first-party effect plug-in: registers the built-in effects through
/// the effect seam (ARCHITECTURE.md, "The effect seam"; GLOSSARY.md,
/// "Effect") — the audio staples (gain and the high-/low-pass filters) and
/// the video staples (color adjustment and blur).
///
/// Like every first-party plug-in it registers through the same
/// `EffectRegistering` seam a third-party effect bundle will use.
public struct EffectPlugIn: PlugIn {
    /// The plug-in's stable identifier, also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.effects")

    /// The user-facing plug-in name.
    public let name = "Effects"

    /// Creates the plug-in.
    public init() {}

    /// Registers the built-in audio and video effect providers.
    public func activate(in context: PlugInContext) async throws {
        try await context.effects.register(GainEffectProvider())
        try await context.effects.register(HighPassEffectProvider())
        try await context.effects.register(LowPassEffectProvider())
        try await context.effects.register(ColorAdjustEffectProvider())
        try await context.effects.register(BlurEffectProvider())
    }
}
