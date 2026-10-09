//
//  ProjectWindow.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// One window the operator added to a project as an input (GLOSSARY.md,
/// "Input"): the document's record of it, from which the app makes the
/// window input on each launch (ARCHITECTURE.md, "Window capture").
///
/// Part of the **project / scripting contract** (CLAUDE.md, "Data Models"):
/// stable camelCase keys, exact round-trip. A window has no identifier that
/// outlives it, so the record is a **description** — the owning application
/// and the title the window had when it was added — and the capture finds
/// the window that fits it. The ``id`` is the project's own: it is the
/// ``InputID`` the input reports, so a layer binds to a window exactly as it
/// binds to a camera, and stays bound while the window is closed. A window
/// that cannot be found is a dormant input, the disconnected-device
/// semantic — the record stays in the document until the operator removes
/// it.
public struct ProjectWindow: Sendable, Equatable, Codable, Identifiable {
    /// The identity the project gives the window, and the identifier of the
    /// input that captures it.
    public let id: InputID

    /// The owning application's bundle identifier, e.g. `com.apple.Keynote`.
    public let bundleIdentifier: String

    /// The owning application's user-facing name, cached so the record still
    /// reads sensibly while the application is not running.
    public let applicationName: String

    /// The window's title when it was added.
    public let title: String

    /// Creates a window record.
    ///
    /// - Parameters:
    ///   - id: The record's identity (default: a fresh one, a new UUID
    ///     string).
    ///   - bundleIdentifier: The owning application's bundle identifier.
    ///   - applicationName: The owning application's user-facing name.
    ///   - title: The window's title.
    public init(
        id: InputID = InputID(rawValue: UUID().uuidString),
        bundleIdentifier: String,
        applicationName: String,
        title: String
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
    }

    /// The coding keys — stable camelCase names for the project document.
    private enum CodingKeys: String, CodingKey {
        case id
        case bundleIdentifier
        case applicationName
        case title
    }
}
