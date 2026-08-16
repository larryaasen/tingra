//
//  Project.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The saved document for a whole show (GLOSSARY.md, "Project"): everything
/// needed to reopen the show exactly as it was — the presets (each with its
/// shots, optional per-shot default transitions, and optional authored audio
/// configuration; see ``Preset/audioChannels``) and the ``destinations`` the
/// program streams to (the stream keys are excluded — they live in secure
/// storage, filed by destination id; see ARCHITECTURE.md, "Streaming the
/// program" and "Multiple destinations"). Further settings join it in later
/// iterations.
///
/// A project is a plain `Codable` value type — the serialized form is the
/// project / scripting contract (CLAUDE.md, "Data Models"), so its JSON keys
/// are stable camelCase and it round-trips exactly. The document carries a
/// required ``version`` so a future format can migrate older documents, and
/// decoding a document **newer** than this build understands throws rather
/// than silently loading (and, on the next save, clobbering) fields this
/// build does not know about. **Pre-release the format is simply version 1**
/// — nothing has shipped, so there are no older documents to migrate and the
/// format grows freely within v1 (optional fields decode forgivingly);
/// version 2 happens the first time the format changes after the first
/// release (ARCHITECTURE.md, "Per-shot default transitions").
public struct Project: Sendable, Equatable, Codable {
    /// The newest document format version this build reads and writes —
    /// version 1 until the first release ships; the format grows within v1
    /// pre-release.
    public static let currentVersion = 1

    /// The document format version this project was written with.
    public let version: Int

    /// The presets the project holds, in switcher order. The document format
    /// holds an array from the start; the app surfaces only the first preset
    /// until multiple presets arrive in the UI.
    public let presets: [Preset]

    /// The saved destinations this project streams to, in the order the
    /// operator listed them, or `nil` when none has been set. One program fans
    /// out to every enabled one (ARCHITECTURE.md, "Multiple destinations").
    ///
    /// **References, not records** (DESTINATIONS.md): each element names a
    /// destination in the operator-global store and says whether this show
    /// streams to it. The name and URL live in the store, and the key lives in
    /// the host's secure storage filed under the same id — neither is ever
    /// written here.
    public let destinations: [DestinationReference]?

    /// Creates a project.
    ///
    /// - Parameters:
    ///   - version: The document format version (default: ``currentVersion``).
    ///   - presets: The presets, in switcher order (default: none).
    ///   - destinations: The destinations this project streams to (default:
    ///     none).
    public init(
        version: Int = Project.currentVersion,
        presets: [Preset] = [],
        destinations: [DestinationReference]? = nil
    ) {
        self.version = version
        self.presets = presets
        self.destinations = destinations
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case version
        case presets
        case destinations
        /// Read-only: the single destination key written before a project
        /// could hold several. Decoded and folded into ``destinations``,
        /// never written again (see ``init(from:)``).
        case destination
    }

    /// Decodes a project. `version` is required (a document must declare its
    /// format so future versions can migrate it) and must not exceed
    /// ``currentVersion``; `presets`, `destinations`, and the older single
    /// `destination` are optional (a minimal document decodes forgivingly
    /// with them absent).
    ///
    /// A document written with the single `destination` key folds it in as
    /// the only element of ``destinations`` — an **optional key within v1**
    /// (the pre-release rule, no version bump), the same accommodation
    /// ``Preset/audioChannels`` made. `destinations` wins when both appear.
    ///
    /// The elements are now ``DestinationReference``s rather than whole
    /// records, and that too is **no version bump**: a document written by the
    /// earlier app carries `url` and `name` keys alongside `id` and
    /// `isEnabled`, and `Codable` ignores keys a type does not read. So an
    /// older document decodes, keeping each destination's identity and enabled
    /// flag; its names and URLs are re-entered once into the operator's store
    /// (DESTINATIONS.md).
    ///
    /// - Throws: `DecodingError.keyNotFound` when `version` is missing, and
    ///   `DecodingError.dataCorrupted` when the document declares a format
    ///   version newer than this build understands — open it with the newer
    ///   Tingra that wrote it instead.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version <= Project.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: """
                    The project document declares format version \(version), but this build of Tingra reads \
                    versions up to \(Project.currentVersion). Open the document with the newer Tingra that wrote it.
                    """
            )
        }
        self.version = version
        presets = try container.decodeIfPresent([Preset].self, forKey: .presets) ?? []
        if let list = try container.decodeIfPresent([DestinationReference].self, forKey: .destinations) {
            destinations = list
        } else if let single = try? container.decodeIfPresent(DestinationReference.self, forKey: .destination) {
            // Read leniently, and only here: the superseded single-destination
            // key predates destination ids, so its record usually cannot become
            // a reference at all. Dropping one unreferenceable legacy key is
            // right; failing the whole document load over it is not — the
            // operator would lose their presets to recover a URL they are
            // re-entering anyway.
            destinations = [single]
        } else {
            destinations = nil
        }
    }

    /// Encodes a project, writing `version` and `presets` always and
    /// `destinations` only when set, so a project with no destination
    /// round-trips to a document without the key (and reads back as nil).
    /// The superseded single `destination` key is never written.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(presets, forKey: .presets)
        try container.encodeIfPresent(destinations, forKey: .destinations)
    }
}
