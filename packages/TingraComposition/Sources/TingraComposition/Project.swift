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
/// needed to reopen the show exactly as it was. Version 1 held the presets
/// only; version 2 adds the ``destination`` configuration (the stream key is
/// excluded — it lives in secure storage; see ARCHITECTURE.md, "Streaming the
/// program"). Further settings join it in later iterations.
///
/// A project is a plain `Codable` value type — the serialized form is the
/// project / scripting contract (CLAUDE.md, "Data Models"), so its JSON keys
/// are stable camelCase and it round-trips exactly. The document carries a
/// required ``version`` so a future format can migrate older documents, and
/// decoding a document **newer** than this build understands throws rather
/// than silently loading (and, on the next save, clobbering) fields this
/// build does not know about. An older document decodes forward: a v1 file
/// (no `destination`) loads cleanly with ``destination`` nil.
public struct Project: Sendable, Equatable, Codable {
    /// The newest document format version this build reads and writes. Bumped
    /// to 2 when ``destination`` was added.
    public static let currentVersion = 2

    /// The document format version this project was written with.
    public let version: Int

    /// The presets the project holds, in switcher order. The document format
    /// holds an array from the start; the app surfaces only the first preset
    /// until multiple presets arrive in the UI.
    public let presets: [Preset]

    /// The stream destination this project last configured, or `nil` when
    /// none has been set. The key is never stored here — only in the host's
    /// secure storage, referenced by this destination's URL (added in
    /// document version 2). One destination in v1 of the app; multiple
    /// destinations are roadmap step 8.
    public let destination: ProjectDestination?

    /// Creates a project.
    ///
    /// - Parameters:
    ///   - version: The document format version (default: ``currentVersion``).
    ///   - presets: The presets, in switcher order (default: none).
    ///   - destination: The stream destination configuration (default: none).
    public init(
        version: Int = Project.currentVersion,
        presets: [Preset] = [],
        destination: ProjectDestination? = nil
    ) {
        self.version = version
        self.presets = presets
        self.destination = destination
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case version
        case presets
        case destination
    }

    /// Decodes a project. `version` is required (a document must declare its
    /// format so future versions can migrate it) and must not exceed
    /// ``currentVersion``; `presets` and `destination` are optional (an older
    /// document that predates a field decodes forward with it absent).
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
        destination = try container.decodeIfPresent(ProjectDestination.self, forKey: .destination)
    }

    /// Encodes a project, writing `version` and `presets` always and
    /// `destination` only when set, so a project with no destination
    /// round-trips to a document without the key (and reads back as nil).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(presets, forKey: .presets)
        try container.encodeIfPresent(destination, forKey: .destination)
    }
}
