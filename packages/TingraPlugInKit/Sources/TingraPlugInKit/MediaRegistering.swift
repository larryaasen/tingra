//
//  MediaRegistering.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The host's media registration seam, as a plug-in sees it: where a
/// plug-in registers the ``MediaInputProvider``s it contributes during
/// ``PlugIn/activate(in:)``.
///
/// Resolution — which provider opens a given file — is the host's side of
/// the registry and not part of this protocol, the same split as
/// ``InputRegistering`` against the host's input registry.
public protocol MediaRegistering: Sendable {
    /// Registers a media input provider contributed by a plug-in.
    ///
    /// Throws a descriptive error if the provider cannot be accepted — for
    /// example, when its identifier is already registered.
    func register(_ provider: any MediaInputProvider) async throws

    /// Removes a previously registered provider — how a plug-in rolls back
    /// a partial activation so a plug-in that cannot activate leaves the
    /// registry as it found it (the generator plug-in's rule). Removing an
    /// identifier that is not registered is harmless and does nothing.
    func unregister(_ id: MediaProviderID) async
}

/// The error the ``UnavailableMediaRegistry`` throws.
public enum MediaRegisteringError: Error, Equatable {
    /// The host constructed its ``PlugInContext`` without a media registry,
    /// so no media provider can be accepted. The fix is on the host's side:
    /// pass a registry to ``PlugInContext/init(eventBus:clock:inputs:outputs:effects:tools:media:)``.
    case registryUnavailable(MediaProviderID)
}

extension MediaRegisteringError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .registryUnavailable(let id):
            return """
                The media provider '\(id.rawValue)' cannot register: the host constructed its plug-in \
                context without a media registry. Pass a MediaRegistering registry to PlugInContext \
                to accept media providers.
                """
        }
    }
}

/// The media seam of a host that accepts no media providers — the default
/// ``PlugInContext/media``, so a host that predates media (the CLI, the
/// daemon, most tests) constructs its context unchanged.
///
/// Registering through it **throws** rather than discarding the provider:
/// a plug-in that contributes media into a host that cannot accept it is a
/// configuration defect worth a reported error, never a silent omission
/// (the same reasoning as the input registry's no-media diagnostic).
public struct UnavailableMediaRegistry: MediaRegistering {
    /// Creates the registry.
    public init() {}

    /// Always throws ``MediaRegisteringError/registryUnavailable(_:)``.
    public func register(_ provider: any MediaInputProvider) async throws {
        throw MediaRegisteringError.registryUnavailable(provider.id)
    }

    /// Nothing is ever registered here, so there is nothing to remove.
    public func unregister(_ id: MediaProviderID) async {}
}
