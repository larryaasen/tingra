//
//  EffectID.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A stable identifier for a registered effect, e.g. `gain` — the effect
/// seam's identity model, shared by audio and video effects
/// (ARCHITECTURE.md, "The effect seam").
///
/// The identifier is part of the project/scripting contract: a persisted
/// effect chain names its effects by `EffectID`
/// (``EffectConfiguration/effect``), so an id must stay stable across
/// releases — renaming one orphans every document that authored it.
/// First-party effects use short camelCase names (`gain`, `highPass`);
/// third-party effects should prefix with their own domain to avoid
/// collisions.
public struct EffectID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
