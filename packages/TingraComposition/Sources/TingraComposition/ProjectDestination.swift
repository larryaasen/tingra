//
//  ProjectDestination.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A destination's stable identity within a project — how a saved
/// destination is named in the status events and, crucially, how its stream
/// key is filed in secure storage.
///
/// Keyed by id rather than by URL because a URL is neither unique nor stable:
/// two destinations can share one ingest URL with different keys, and editing
/// a URL would orphan the key stored under the old one. The id survives both
/// (ARCHITECTURE.md, "Multiple destinations").
public struct ProjectDestinationID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string — a UUID by default, or a caller-chosen stable
    /// token.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fresh, unique identifier (a new UUID string).
    public init() {
        self.rawValue = UUID().uuidString
    }
}

/// A destination configuration saved in a ``Project`` (GLOSSARY.md,
/// "Destination"): where the program streams to, minus the secret.
///
/// Deliberately **key-free**: the stream key is a secret and lives only in
/// the host's Keychain-backed secure storage (CLAUDE.md, "Error Handling";
/// EVENTS.md, Redaction), filed under this destination's ``id``. The plug-in
/// seam's `Destination` (in TingraPlugInKit) carries the key at stream time
/// and is *not* `Codable` for exactly that reason; this document type is
/// `Codable` precisely *because* it holds no secret — the two are separate
/// on purpose.
///
/// A project holds a list of these and streams to all the enabled ones at
/// once, as one program fanned out to N legs (ARCHITECTURE.md, "Multiple
/// destinations"). Per-destination compression settings are a later
/// iteration; today every leg encodes with the program's settings.
///
/// A plain `Codable` value type on the project / scripting contract (stable
/// camelCase keys, exact round-trip), like ``Preset``/``Shot``/``Layer``.
public struct ProjectDestination: Sendable, Equatable, Codable, Identifiable {
    /// The destination's stable identity — what its stream key is filed
    /// under in secure storage, and what its status events report.
    public let id: ProjectDestinationID

    /// The RTMP(S) or SRT destination URL, e.g. `rtmp://live.twitch.tv/app`.
    /// The stream key is never part of the URL stored here.
    public let url: URL

    /// The operator's label for this destination ("Twitch", "YouTube
    /// backup") — what the streaming panel lists it as. Empty when unnamed,
    /// in which case a caller shows the URL instead.
    public let name: String

    /// Whether this destination is streamed to. A disabled destination stays
    /// in the project — keys, name, and all — but contributes no leg to the
    /// next stream, so an operator can park a destination without deleting
    /// and re-entering it.
    public let isEnabled: Bool

    /// Creates a destination configuration.
    ///
    /// - Parameters:
    ///   - id: The stable identity (default: a fresh one).
    ///   - url: The RTMP(S) or SRT destination URL (no embedded key).
    ///   - name: The operator's label (default empty).
    ///   - isEnabled: Whether it is streamed to (default yes).
    public init(
        id: ProjectDestinationID = ProjectDestinationID(),
        url: URL,
        name: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.isEnabled = isEnabled
    }

    /// The coding keys — stable camelCase names for the document.
    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case name
        case isEnabled
    }

    /// Decodes a destination. `url` is required; `id`, `name`, and
    /// `isEnabled` are **optional keys within v1** (the pre-release rule, no
    /// version bump), so a document written before destinations grew an
    /// identity still decodes — it gains a fresh id, no name, and is
    /// enabled.
    ///
    /// - Throws: `DecodingError.keyNotFound` when `url` is missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        id = try container.decodeIfPresent(ProjectDestinationID.self, forKey: .id) ?? ProjectDestinationID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
