//
//  DestinationReference.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-08-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A project's use of one destination: which saved destination the show
/// streams to, and whether that leg is enabled (DESTINATIONS.md, "The
/// decision: destinations belong to the operator, not the project").
///
/// The destination itself — its name and URL — is **operator-global** and
/// lives in the host's destination store, not here. A Twitch account is not
/// per-show: the same ingest endpoints recur across every project, so the
/// project records only the part that genuinely is per-show. That split is why
/// this type holds no `url` and no `name`: duplicating them would let a
/// project's copy drift from the operator's.
///
/// This supersedes ``ProjectDestination``, which held the whole record. A
/// document written by the earlier app decodes into this type unchanged —
/// `Codable` ignores the `url` and `name` keys it no longer reads — so the id
/// and the enabled flag survive, and only the name and URL are re-entered
/// once, exactly as DESTINATIONS.md accepted.
///
/// A plain `Codable` value type on the project / scripting contract (stable
/// camelCase keys, exact round-trip), like ``Preset``/``Shot``/``Layer``.
public struct DestinationReference: Sendable, Equatable, Codable, Identifiable {
    /// The saved destination this project streams to — the store's id for it,
    /// carried as the document's own id type because `TingraComposition` does
    /// not depend on the host. The two are the same string; the app converts
    /// at the boundary.
    ///
    /// A reference whose id names no saved destination is **dangling** and is
    /// dropped when the project loads: a destination the operator deleted from
    /// the store is gone from every project that used it, which is what
    /// operator-global ownership means.
    public let id: ProjectDestinationID

    /// Whether this destination is streamed to. A disabled reference stays in
    /// the project — the saved destination keeps its name, URL, and key — but
    /// contributes no leg to the next stream, so an operator can park a
    /// destination for one show without deleting it for every show.
    public let isEnabled: Bool

    /// Creates a reference to a saved destination.
    ///
    /// - Parameters:
    ///   - id: The saved destination's stable id.
    ///   - isEnabled: Whether it is streamed to (default yes).
    public init(id: ProjectDestinationID, isEnabled: Bool = true) {
        self.id = id
        self.isEnabled = isEnabled
    }

    /// The coding keys — stable camelCase names for the document.
    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
    }

    /// Decodes a reference. `id` is required — a reference that names no
    /// destination refers to nothing and cannot be repaired by defaulting —
    /// while `isEnabled` is optional and defaults to enabled, matching
    /// ``ProjectDestination``'s forgiving reading of the same key.
    ///
    /// - Throws: `DecodingError.keyNotFound` when `id` is missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProjectDestinationID.self, forKey: .id)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
