//
//  OutputRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Errors thrown by ``OutputRegistry``.
public enum OutputRegistryError: Error, Equatable {
    /// Another provider already serves one of the schemes this provider
    /// declares. One provider per scheme; the fix is for the plug-in to
    /// serve a scheme nothing else claims.
    case duplicateScheme(String, existing: OutputID)
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
    /// The registered providers, keyed by the lowercase URL schemes they
    /// serve.
    private var providersByScheme: [String: any StreamingServiceProvider] = [:]

    /// Creates an empty registry. The host owns one per engine.
    public init() {}

    /// Registers a streaming service provider contributed by a plug-in.
    ///
    /// Throws ``OutputRegistryError/duplicateScheme(_:existing:)`` if
    /// another provider already serves one of its schemes — a plug-in
    /// defect surfaces as a thrown error, never a trap (CLAUDE.md,
    /// never-crash rule). Schemes match case-insensitively.
    public func register(_ provider: any StreamingServiceProvider) throws {
        let schemes = provider.schemes.map { $0.lowercased() }
        for scheme in schemes {
            if let existing = providersByScheme[scheme] {
                throw OutputRegistryError.duplicateScheme(scheme, existing: existing.id)
            }
        }
        for scheme in schemes {
            providersByScheme[scheme] = provider
        }
    }

    /// The provider serving the given URL scheme, if one is registered.
    /// Schemes match case-insensitively.
    public func provider(forScheme scheme: String) -> (any StreamingServiceProvider)? {
        providersByScheme[scheme.lowercased()]
    }
}

/// The registry is the concrete `OutputRegistering` seam the host hands
/// plug-ins through `PlugInContext.outputs`.
extension OutputRegistry: OutputRegistering {}
