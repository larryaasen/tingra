//
//  ResourceRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Errors thrown by ``ResourceRegistry``.
public enum ResourceRegistryError: Error, Equatable {
    /// A resource at the same URI is already registered. URIs are unique
    /// and append-only (an MCP scripting contract); the fix is to give every
    /// resource a distinct URI.
    case duplicateResource(String)
}

extension ResourceRegistryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateResource(let uri):
            return """
                A resource at '\(uri)' is already registered. Resource URIs are unique and a stable \
                MCP contract; whatever contributes this resource must give it a URI no other resource \
                claims.
                """
        }
    }
}

/// Where the engine's observable state is registered as MCP resources
/// (PLUGINS.md, "Phase 2 — seams into the engine"): the MCP/Control
/// service lists, reads, and subscribes to resources from here, the way it
/// dispatches tools from ``ToolRegistry``. The app fills it from its model;
/// the daemon's stays empty until the engine it owns has state worth
/// observing beyond `stream_status`. A plug-in-contributed resource seam
/// (`ResourceRegistering`) is Phase 4's, so this registry is host-owned for
/// now and takes no registration from a plug-in context.
///
/// One registry instance per host, injected — never a global.
public actor ResourceRegistry {
    /// The registered resources, keyed by URI.
    private var resourcesByURI: [String: any Resource] = [:]

    /// The order resources were registered in, so listing is stable.
    private var registrationOrder: [String] = []

    /// Creates an empty registry. The host owns one per engine.
    public init() {}

    /// Registers a resource.
    ///
    /// - Parameter resource: The resource.
    /// - Throws: ``ResourceRegistryError/duplicateResource(_:)`` if the URI
    ///   is already taken — a defect surfaces as a thrown error, never a
    ///   trap (CLAUDE.md, never-crash rule).
    public func register(_ resource: any Resource) throws {
        guard resourcesByURI[resource.uri] == nil else {
            throw ResourceRegistryError.duplicateResource(resource.uri)
        }
        resourcesByURI[resource.uri] = resource
        registrationOrder.append(resource.uri)
    }

    /// The resource registered at the given URI, if any.
    ///
    /// - Parameter uri: The URI, e.g. `tingra://session`.
    public func resource(at uri: String) -> (any Resource)? {
        resourcesByURI[uri]
    }

    /// Every registered resource, in registration order — what the
    /// MCP/Control service returns from `resources/list`.
    public var allResources: [any Resource] {
        registrationOrder.compactMap { resourcesByURI[$0] }
    }
}
