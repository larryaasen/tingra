//
//  MonitorOverlayID.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A stable identifier for a registered monitor overlay, e.g. `titleSafe`
/// (GLOSSARY.md, "Monitor overlay"; PLUGINS.md, Decisions 52–57).
///
/// The identifier is part of the project contract: a project saves which
/// monitor overlays are on by naming them, so an id must stay stable
/// across releases, since renaming one turns that overlay off in every
/// project that showed it. First-party overlays use short camelCase names
/// (`tallyBorder`, `titleSafe`); third-party overlays should prefix with
/// their own domain to avoid collisions.
public struct MonitorOverlayID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
