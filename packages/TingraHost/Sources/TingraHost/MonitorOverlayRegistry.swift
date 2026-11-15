//
//  MonitorOverlayRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Errors thrown by ``MonitorOverlayRegistry``.
public enum MonitorOverlayRegistryError: Error, Equatable {
    /// Another monitor overlay provider already uses this id. The fix is
    /// for the plug-in to use an id nothing else claims (third parties
    /// should prefix with their own domain).
    case duplicateOverlay(MonitorOverlayID)
}

extension MonitorOverlayRegistryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateOverlay(let id):
            return """
                A monitor overlay with the id '\(id.rawValue)' is already registered. One provider \
                per id: the plug-in contributing this overlay must use an id no other monitor overlay \
                claims (third-party overlays should prefix ids with their own domain).
                """
        }
    }
}

/// The seam where monitor overlay plug-ins attach (PLUGINS.md, Decision
/// 53): plug-ins register the ``MonitorOverlayProvider``s they contribute,
/// and a front end with monitors lists them in its Overlays submenus and
/// makes each monitor's overlays from them.
///
/// One provider per id, listed in registration order, so the first-party
/// plug-in's fixed order is the menu's order. One registry instance per
/// host; plug-ins receive it through the registration path, never as a
/// global.
public actor MonitorOverlayRegistry {
    /// The registered providers, keyed by id.
    private var providersByID: [MonitorOverlayID: any MonitorOverlayProvider] = [:]

    /// The registered ids, in registration order.
    private var order: [MonitorOverlayID] = []

    /// Creates an empty registry. The host owns one per engine.
    public init() {}

    /// Registers a monitor overlay provider contributed by a plug-in.
    ///
    /// - Parameter provider: The provider to register.
    /// - Throws: ``MonitorOverlayRegistryError/duplicateOverlay(_:)`` if
    ///   another provider already uses its id: a plug-in defect surfaces as
    ///   a thrown error, never a trap.
    public func register(_ provider: any MonitorOverlayProvider) throws {
        guard providersByID[provider.id] == nil else {
            throw MonitorOverlayRegistryError.duplicateOverlay(provider.id)
        }
        providersByID[provider.id] = provider
        order.append(provider.id)
    }

    /// The provider with the given id, if one is registered.
    ///
    /// - Parameter id: The overlay's identifier.
    /// - Returns: The provider, or `nil`.
    public func provider(withID id: MonitorOverlayID) -> (any MonitorOverlayProvider)? {
        providersByID[id]
    }

    /// Every registered provider, in registration order.
    public var allProviders: [any MonitorOverlayProvider] {
        order.compactMap { providersByID[$0] }
    }
}

/// The registry is the concrete `MonitorOverlayRegistering` seam the host
/// hands plug-ins through `PlugInContext.monitorOverlays`.
extension MonitorOverlayRegistry: MonitorOverlayRegistering {}
