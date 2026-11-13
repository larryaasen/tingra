//
//  ProjectApplication.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// One application the operator added to a project as an audio input
/// (GLOSSARY.md, "Input"): the document's record of it, from which the app
/// makes the application input on each launch (ARCHITECTURE.md,
/// "Application audio", A1).
///
/// Part of the **project / scripting contract** (CLAUDE.md, "Data Models"):
/// stable camelCase keys, exact round-trip. An application is found again by
/// its bundle identifier; the ``id`` is the project's own — the ``InputID``
/// the input reports, so the channel strip keeps its settings while the
/// application is not running. An application that is not running is a
/// dormant input, the disconnected-device semantic: the record stays in the
/// document until the operator removes it.
public struct ProjectApplication: Sendable, Equatable, Codable, Identifiable {
    /// The identity the project gives the application, and the identifier of
    /// the input that captures it.
    public let id: InputID

    /// The application's bundle identifier, e.g. `com.apple.Music`.
    public let bundleIdentifier: String

    /// The application's user-facing name, cached so the record still reads
    /// sensibly while the application is not running.
    public let name: String

    /// Creates an application record.
    ///
    /// - Parameters:
    ///   - id: The record's identity (default: a fresh one, a new UUID
    ///     string).
    ///   - bundleIdentifier: The application's bundle identifier.
    ///   - name: The application's user-facing name.
    public init(
        id: InputID = InputID(rawValue: UUID().uuidString),
        bundleIdentifier: String,
        name: String
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case id
        case bundleIdentifier
        case name
    }
}
