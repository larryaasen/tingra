//
//  ProjectMedia.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// A stable identifier for a media item in a project — and, by the same
/// string, the ``InputID`` of the input that plays it, so a layer binds to
/// media exactly as it binds to a camera.
public struct MediaID: RawRepresentable, Hashable, Sendable, Codable {
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

    /// The identifier of the input that plays this media item.
    public var inputID: InputID {
        InputID(rawValue: rawValue)
    }
}

/// One file the operator added to a project as media (GLOSSARY.md): the
/// document's record of it, from which the app asks the media registry for
/// the input that plays it on each launch (ARCHITECTURE.md, "Media inputs
/// and the Library's Media tab").
///
/// Part of the **project / scripting contract** (CLAUDE.md, "Data Models"):
/// stable camelCase keys, exact round-trip. The file is referenced by its
/// **absolute path**, not a security-scoped bookmark: the app is not
/// sandboxed, and a legible path in a document the operator can read beats
/// opaque data that exists to satisfy a sandbox the app does not have. A
/// file that has moved away is a dormant input, the disconnected-device
/// semantic — the item stays in the document until the operator removes it.
public struct ProjectMedia: Sendable, Equatable, Codable, Identifiable {
    /// The item's stable identity, shared with the input that plays it.
    public let id: MediaID

    /// The file's absolute path.
    public let path: String

    /// The user-facing name — the file name as added, cached so the item
    /// still reads sensibly while the file is absent.
    public let name: String

    /// The file, as a URL.
    public var url: URL {
        URL(filePath: path)
    }

    /// Creates a media item for a file.
    ///
    /// - Parameters:
    ///   - id: The item's identity (default: a fresh one).
    ///   - url: The file. Stored as its absolute path.
    ///   - name: The user-facing name (default: the file's name).
    public init(id: MediaID = MediaID(), url: URL, name: String? = nil) {
        self.id = id
        self.path = url.standardizedFileURL.path(percentEncoded: false)
        self.name = name ?? url.lastPathComponent
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case name
    }
}
