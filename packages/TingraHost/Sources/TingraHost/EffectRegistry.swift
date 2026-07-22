//
//  EffectRegistry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Errors thrown by ``EffectRegistry``.
public enum EffectRegistryError: Error, Equatable {
    /// Another audio effect provider already uses this id. One provider
    /// per id and media kind; the fix is for the plug-in to use an id
    /// nothing else claims (third parties should prefix with their own
    /// domain).
    case duplicateAudioEffect(EffectID)

    /// Another video effect provider already uses this id (see
    /// ``duplicateAudioEffect(_:)``).
    case duplicateVideoEffect(EffectID)
}

extension EffectRegistryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateAudioEffect(let id):
            return """
                An audio effect with the id '\(id.rawValue)' is already registered. One provider \
                per id: the plug-in contributing this effect must use an id no other audio effect \
                claims (third-party effects should prefix ids with their own domain).
                """
        case .duplicateVideoEffect(let id):
            return """
                A video effect with the id '\(id.rawValue)' is already registered. One provider \
                per id: the plug-in contributing this effect must use an id no other video effect \
                claims (third-party effects should prefix ids with their own domain).
                """
        }
    }
}

/// The seam where effect plug-ins attach: plug-ins register the audio and
/// video effect providers they contribute, and the engine resolves a
/// persisted chain entry's ``EffectID`` to a provider when it instantiates
/// the chain (see ARCHITECTURE.md, "The effect seam").
///
/// One registry, two provider kinds — audio and video effects share the
/// identity model but live in separate tables, so an audio and a video
/// effect may (unusually) share an id without colliding; within a kind,
/// one provider per id.
///
/// One registry instance per host; plug-ins receive it through the
/// registration path, never as a global.
public actor EffectRegistry {
    /// The registered audio effect providers, keyed by id.
    private var audioProvidersByID: [EffectID: any AudioEffectProvider] = [:]

    /// The registered audio effect ids, in registration order — the
    /// stable listing order for effect menus.
    private var audioOrder: [EffectID] = []

    /// The registered video effect providers, keyed by id.
    private var videoProvidersByID: [EffectID: any VideoEffectProvider] = [:]

    /// The registered video effect ids, in registration order (see
    /// ``audioOrder``).
    private var videoOrder: [EffectID] = []

    /// Creates an empty registry. The host owns one per engine.
    public init() {}

    /// Registers an audio effect provider contributed by a plug-in.
    ///
    /// Throws ``EffectRegistryError/duplicateAudioEffect(_:)`` if another
    /// audio effect already uses its id — a plug-in defect surfaces as a
    /// thrown error, never a trap (CLAUDE.md, never-crash rule).
    public func register(_ provider: any AudioEffectProvider) throws {
        guard audioProvidersByID[provider.id] == nil else {
            throw EffectRegistryError.duplicateAudioEffect(provider.id)
        }
        audioProvidersByID[provider.id] = provider
        audioOrder.append(provider.id)
    }

    /// Registers a video effect provider contributed by a plug-in.
    ///
    /// Throws ``EffectRegistryError/duplicateVideoEffect(_:)`` if another
    /// video effect already uses its id (see the audio overload).
    public func register(_ provider: any VideoEffectProvider) throws {
        guard videoProvidersByID[provider.id] == nil else {
            throw EffectRegistryError.duplicateVideoEffect(provider.id)
        }
        videoProvidersByID[provider.id] = provider
        videoOrder.append(provider.id)
    }

    /// The audio effect provider with the given id, if one is registered.
    public func audioProvider(withID id: EffectID) -> (any AudioEffectProvider)? {
        audioProvidersByID[id]
    }

    /// The video effect provider with the given id, if one is registered.
    public func videoProvider(withID id: EffectID) -> (any VideoEffectProvider)? {
        videoProvidersByID[id]
    }

    /// Every registered audio effect provider, in registration order —
    /// the stable listing an effect menu shows.
    public var allAudioProviders: [any AudioEffectProvider] {
        audioOrder.compactMap { audioProvidersByID[$0] }
    }

    /// Every registered video effect provider, in registration order (see
    /// ``allAudioProviders``).
    public var allVideoProviders: [any VideoEffectProvider] {
        videoOrder.compactMap { videoProvidersByID[$0] }
    }
}

/// The registry is the concrete `EffectRegistering` seam the host hands
/// plug-ins through `PlugInContext.effects`.
extension EffectRegistry: EffectRegistering {}
