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
/// needed to reopen the show exactly as it was. Version 1 of the document
/// holds the presets only; destination configurations and settings join it in
/// later iterations (see ARCHITECTURE.md, "Project save/load").
///
/// A project is a plain `Codable` value type — the serialized form is the
/// project / scripting contract (CLAUDE.md, "Data Models"), so its JSON keys
/// are stable camelCase and it round-trips exactly. The document carries a
/// required ``version`` so a future format can migrate older documents, and
/// decoding a document **newer** than this build understands throws rather
/// than silently loading (and, on the next save, clobbering) fields this
/// build does not know about.
public struct Project: Sendable, Equatable, Codable {
    /// The newest document format version this build reads and writes.
    public static let currentVersion = 1

    /// The document format version this project was written with.
    public let version: Int

    /// The presets the project holds, in switcher order. The document format
    /// holds an array from the start; the app surfaces only the first preset
    /// until multiple presets arrive in the UI.
    public let presets: [Preset]

    /// Creates a project.
    ///
    /// - Parameters:
    ///   - version: The document format version (default: ``currentVersion``).
    ///   - presets: The presets, in switcher order (default: none).
    public init(version: Int = Project.currentVersion, presets: [Preset] = []) {
        self.version = version
        self.presets = presets
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case version
        case presets
    }

    /// Decodes a project. `version` is required (a document must declare its
    /// format so future versions can migrate it) and must not exceed
    /// ``currentVersion``; `presets` is optional and defaults to empty.
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
    }

    /// Encodes a project, always writing every field so the document
    /// round-trips exactly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(presets, forKey: .presets)
    }
}
