//
//  MediaInputProvider.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import UniformTypeIdentifiers

/// A stable identifier for a media input provider, e.g.
/// `com.moonwink.tingra.media.image`.
public struct MediaProviderID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A plug-in's factory for media inputs: ``Input``s whose content comes
/// from a file the operator added to a project (``InputKind/media``).
///
/// A file is *added*, not discovered, so a plug-in cannot register media
/// inputs during ``PlugIn/activate(in:)`` the way capture and generator
/// plug-ins register theirs. It registers a provider instead — one per
/// family of content types — through ``PlugInContext/media``, and the host
/// resolves each added file to the provider whose ``contentTypes`` it
/// conforms to, asks it for an input, and registers that input on the
/// project's behalf. The same shape as ``StreamingServiceProvider``
/// resolved by URL scheme (ARCHITECTURE.md, "Media inputs and the
/// Library's Media tab").
public protocol MediaInputProvider: Sendable {
    /// The provider's stable identifier.
    var id: MediaProviderID { get }

    /// A short user-facing name, e.g. "Image".
    var name: String { get }

    /// The uniform types this provider opens, e.g. `[.image]`. A file
    /// resolves to the first registered provider one of whose types it
    /// conforms to, so a provider declares the broadest type it truly
    /// handles and nothing wider.
    var contentTypes: [UTType] { get }

    /// Creates the input that plays the given file.
    ///
    /// The input is created, not started: it acquires nothing until
    /// ``Input/start()``, which is where a file that cannot be read
    /// reports itself. The provider keeps the clock and event bus it
    /// was activated with, so this takes only what differs per file.
    ///
    /// - Parameters:
    ///   - url: The file to play.
    ///   - id: The stable identifier the input must report as ``Input/id``
    ///     — the project's identity for the file, so a layer bound to it
    ///     survives relaunches.
    /// - Returns: A fresh input; the host owns its lifecycle.
    /// - Throws: A descriptive error if the file cannot become an input at
    ///   all — a type the provider does not open, or a path that is not a
    ///   file URL.
    func makeInput(for url: URL, id: InputID) throws -> any Input
}
