//
//  MediaRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit
import UniformTypeIdentifiers

/// Errors the media registry throws — all recoverable, all descriptive, per
/// the never-crash rule (CLAUDE.md).
public enum MediaRegistryError: Error, Equatable {
    /// A provider with the same identifier is already registered. The fix is
    /// for the plug-in to give every provider it contributes a distinct,
    /// stable identifier.
    case duplicateProvider(MediaProviderID)

    /// No registered provider opens the file's content type — the file
    /// carries an extension nothing installed understands, or none at all.
    case unsupportedFile(URL)

    /// The URL is not a file URL; media is always a local file.
    case notAFileURL(URL)
}

extension MediaRegistryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateProvider(let id):
            return """
                A media provider with the identifier '\(id.rawValue)' is already registered. \
                Each provider must have a distinct, stable identifier; the plug-in contributing \
                this provider should use its own reverse-DNS prefix so identifiers never collide.
                """
        case .unsupportedFile(let url):
            return """
                No media plug-in opens '\(url.lastPathComponent)': its content type matches none of \
                the registered providers. Add a file of a supported type (an image, a movie, or a \
                text or Markdown document), or install a plug-in that opens this one.
                """
        case .notAFileURL(let url):
            return """
                '\(url.absoluteString)' is not a file URL. Media is always a local file; drop or \
                choose a file on this Mac.
                """
        }
    }
}

/// The host's media registry: where media plug-ins register their
/// ``MediaInputProvider``s and where the host resolves a file the operator
/// added to the provider that opens it (ARCHITECTURE.md, "Media inputs and
/// the Library's Media tab").
///
/// The same shape as ``OutputRegistry`` resolving a URL scheme to a
/// streaming provider, with the content type as the key: a file resolves to
/// the **first registered** provider one of whose declared types it
/// conforms to, in registration order, so a plug-in that declares
/// `public.image` opens every image format ImageIO reads and a later
/// plug-in cannot take one of those formats from it. An actor, like the
/// other registries: registrations arrive from plug-in activation and
/// resolutions from the app, and neither may see a half-updated list.
public actor MediaRegistry {
    /// The registered providers, in registration order — the order
    /// resolution consults them in.
    private var providers: [any MediaInputProvider] = []

    /// Creates an empty registry. The host owns one per engine.
    public init() {}

    /// Registers a media input provider contributed by a plug-in.
    ///
    /// Throws ``MediaRegistryError/duplicateProvider(_:)`` if the identifier
    /// is already taken — a plug-in defect surfaces as a thrown error, never
    /// a trap (CLAUDE.md, never-crash rule). Overlapping content types are
    /// **not** an error: resolution order settles them, and refusing a
    /// second image provider would cost the host a capability over a
    /// declaration that may be intentional (a RAW-only provider declaring
    /// `public.image` as its family).
    public func register(_ provider: any MediaInputProvider) throws {
        guard !providers.contains(where: { $0.id == provider.id }) else {
            throw MediaRegistryError.duplicateProvider(provider.id)
        }
        providers.append(provider)
    }

    /// Removes a previously registered provider — how a plug-in rolls back
    /// a partial activation. Removing an identifier that is not registered
    /// is harmless and does nothing.
    public func unregister(_ id: MediaProviderID) {
        providers.removeAll { $0.id == id }
    }

    /// Every registered provider, in registration order.
    public var allProviders: [any MediaInputProvider] {
        providers
    }

    /// The union of every registered provider's content types, in
    /// registration order — what a file importer or a drop target accepts.
    public var acceptedContentTypes: [UTType] {
        var seen: Set<UTType> = []
        return providers.flatMap(\.contentTypes).filter { seen.insert($0).inserted }
    }

    /// The first registered provider that opens the given content type,
    /// by conformance (`public.png` conforms to `public.image`), or nil
    /// when none does.
    public func provider(for contentType: UTType) -> (any MediaInputProvider)? {
        providers.first { provider in
            provider.contentTypes.contains { contentType.conforms(to: $0) }
        }
    }

    /// The first registered provider that opens the given file, or nil when
    /// the file's content type is unknown or matches no provider. The type
    /// is resolved by ``contentType(of:)``.
    public func provider(for url: URL) -> (any MediaInputProvider)? {
        guard let contentType = Self.contentType(of: url) else { return nil }
        return provider(for: contentType)
    }

    /// Creates the input that plays the given file, through the provider
    /// that opens it.
    ///
    /// - Parameters:
    ///   - url: The file to play.
    ///   - id: The stable identifier the input reports as ``Input/id`` —
    ///     the project's identity for the file.
    /// - Returns: A fresh input; the caller owns its lifecycle.
    /// - Throws: ``MediaRegistryError/notAFileURL(_:)`` for a non-file URL,
    ///   ``MediaRegistryError/unsupportedFile(_:)`` when no provider opens
    ///   the file, or whatever the provider throws making the input.
    public func makeInput(for url: URL, id: InputID) throws -> any Input {
        guard url.isFileURL else { throw MediaRegistryError.notAFileURL(url) }
        guard let provider = provider(for: url) else { throw MediaRegistryError.unsupportedFile(url) }
        return try provider.makeInput(for: url, id: id)
    }

    /// The content type of a file: what the file system reports for an
    /// existing file, falling back to the type its extension implies for
    /// one that is absent (a project's media file moved away still resolves
    /// to a provider, so the missing file can be reported as that provider's
    /// kind of media), or nil when neither says anything.
    ///
    /// - Parameter url: The file.
    /// - Returns: Its content type, or nil.
    public nonisolated static func contentType(of url: URL) -> UTType? {
        if let reported = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return reported
        }
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }
}

extension MediaRegistry: MediaRegistering {}
