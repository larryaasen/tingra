//
//  OutputRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Errors thrown by ``OutputRegistry``.
public enum OutputRegistryError: Error, Equatable {
    /// Another provider already serves one of the schemes this provider
    /// declares. One provider per scheme; the fix is for the plug-in to
    /// serve a scheme nothing else claims.
    case duplicateScheme(String, existing: OutputID)

    /// Another recording provider already serves one of the file extensions
    /// this provider declares. One provider per extension; the fix is for
    /// the plug-in to serve an extension no other recording output claims.
    case duplicateFileExtension(String, existing: OutputID)

    /// A destination template the provider contributes points at a URL
    /// scheme the provider does not serve, so a destination made from it
    /// could never stream. A template is offered only by an output that can
    /// reach it; the fix is for the plug-in to correct the template's URL or
    /// to serve its scheme (DESTINATIONS.md, "Destination templates").
    case templateSchemeNotServed(templateID: String, scheme: String, provider: OutputID)
}

extension OutputRegistryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateScheme(let scheme, let existing):
            return """
                The URL scheme '\(scheme)' is already served by the registered output \
                '\(existing.rawValue)'. One provider per scheme: the plug-in contributing \
                this provider must serve a scheme no other output claims.
                """
        case .duplicateFileExtension(let ext, let existing):
            return """
                The file extension '\(ext)' is already served by the registered recording \
                output '\(existing.rawValue)'. One provider per extension: the plug-in \
                contributing this provider must serve an extension no other output claims.
                """
        case .templateSchemeNotServed(let templateID, let scheme, let provider):
            return """
                The destination template '\(templateID)' contributed by the output '\(provider.rawValue)' \
                uses the URL scheme '\(scheme)', which that output does not serve, so a destination made \
                from it could never stream. The plug-in must correct the template's URL or serve its scheme.
                """
        }
    }
}

/// The seam where output plug-ins attach: plug-ins register the streaming
/// service providers they contribute, and the engine resolves a
/// destination to a provider by its URL scheme (see ARCHITECTURE.md, "The
/// output registration seam").
///
/// One registry instance per host; plug-ins receive it through the
/// registration path, never as a global.
public actor OutputRegistry {
    /// The registered streaming providers, keyed by the lowercase URL
    /// schemes they serve.
    private var providersByScheme: [String: any StreamingServiceProvider] = [:]

    /// The registered recording providers, keyed by the lowercase file
    /// extensions they serve.
    private var recordingProvidersByExtension: [String: any RecordingServiceProvider] = [:]

    /// Creates an empty registry. The host owns one per engine.
    public init() {}

    /// Registers a streaming service provider contributed by a plug-in.
    ///
    /// Throws ``OutputRegistryError/duplicateScheme(_:existing:)`` if
    /// another provider already serves one of its schemes — a plug-in
    /// defect surfaces as a thrown error, never a trap (CLAUDE.md,
    /// never-crash rule). Schemes match case-insensitively.
    ///
    /// Also throws ``OutputRegistryError/templateSchemeNotServed(templateID:scheme:provider:)``
    /// if one of the provider's destination templates points at a scheme the
    /// provider does not serve — a template no destination could stream
    /// through. Nothing is registered when either check throws.
    public func register(_ provider: any StreamingServiceProvider) throws {
        let schemes = provider.schemes.map { $0.lowercased() }
        for scheme in schemes {
            if let existing = providersByScheme[scheme] {
                throw OutputRegistryError.duplicateScheme(scheme, existing: existing.id)
            }
        }
        for template in provider.destinationTemplates {
            let scheme = template.url.scheme?.lowercased() ?? ""
            guard schemes.contains(scheme) else {
                throw OutputRegistryError.templateSchemeNotServed(
                    templateID: template.id, scheme: scheme, provider: provider.id)
            }
        }
        for scheme in schemes {
            providersByScheme[scheme] = provider
        }
    }

    /// Registers a recording service provider contributed by a plug-in.
    ///
    /// Throws ``OutputRegistryError/duplicateFileExtension(_:existing:)`` if
    /// another recording provider already serves one of its extensions — a
    /// plug-in defect surfaces as a thrown error, never a trap (CLAUDE.md,
    /// never-crash rule). Extensions match case-insensitively.
    public func register(_ provider: any RecordingServiceProvider) throws {
        let extensions = provider.fileExtensions.map { $0.lowercased() }
        for ext in extensions {
            if let existing = recordingProvidersByExtension[ext] {
                throw OutputRegistryError.duplicateFileExtension(ext, existing: existing.id)
            }
        }
        for ext in extensions {
            recordingProvidersByExtension[ext] = provider
        }
    }

    /// The provider serving the given URL scheme, if one is registered.
    /// Schemes match case-insensitively.
    public func provider(forScheme scheme: String) -> (any StreamingServiceProvider)? {
        providersByScheme[scheme.lowercased()]
    }

    /// Every registered streaming provider's destination templates, sorted
    /// by name — what a host offers when the operator adds a destination
    /// (DESTINATIONS.md, "Destination templates").
    ///
    /// Each provider contributes once, however many schemes it serves, and
    /// the order is stable: name first, then URL, so two providers offering
    /// a service of the same name always list in the same order.
    public var destinationTemplates: [DestinationTemplate] {
        var seenProviders: Set<OutputID> = []
        var templates: [DestinationTemplate] = []
        for provider in providersByScheme.values where seenProviders.insert(provider.id).inserted {
            templates += provider.destinationTemplates
        }
        return templates.sorted {
            let byName = $0.name.localizedStandardCompare($1.name)
            guard byName == .orderedSame else { return byName == .orderedAscending }
            return $0.url.absoluteString < $1.url.absoluteString
        }
    }

    /// The recording provider serving the given file extension, if one is
    /// registered. Extensions match case-insensitively.
    public func recordingProvider(forFileExtension ext: String) -> (any RecordingServiceProvider)? {
        recordingProvidersByExtension[ext.lowercased()]
    }
}

/// The registry is the concrete `OutputRegistering` seam the host hands
/// plug-ins through `PlugInContext.outputs`.
extension OutputRegistry: OutputRegistering {}
