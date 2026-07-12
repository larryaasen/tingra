//
//  ProjectDestination.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A destination configuration saved in a ``Project`` (GLOSSARY.md,
/// "Destination"): where the program streams to, minus the secret.
///
/// Deliberately **key-free**: the RTMP(S) stream key is a secret and lives
/// only in the host's Keychain-backed secure storage (CLAUDE.md, "Error
/// Handling"; EVENTS.md, Redaction), referenced by this destination's URL.
/// The plug-in seam's `Destination` (in TingraPlugInKit) carries the key at
/// stream time and is *not* `Codable` for exactly that reason; this document
/// type is `Codable` precisely *because* it holds no secret — the two are
/// separate on purpose.
///
/// A plain `Codable` value type on the project / scripting contract (stable
/// camelCase keys, exact round-trip), like ``Preset``/``Shot``/``Layer``. V1
/// of the field holds the URL only; per-destination compression settings and
/// a user-facing name join it in later iterations (multiple destinations are
/// roadmap step 8).
public struct ProjectDestination: Sendable, Equatable, Codable {
    /// The RTMP(S) destination URL, e.g. `rtmp://live.twitch.tv/app`. The
    /// stream key is never part of the URL stored here — it is kept in secure
    /// storage under this URL.
    public let url: URL

    /// Creates a destination configuration.
    ///
    /// - Parameter url: The RTMP(S) destination URL (no embedded key).
    public init(url: URL) {
        self.url = url
    }

    /// The coding keys — stable camelCase names for the document.
    private enum CodingKeys: String, CodingKey {
        case url
    }
}
