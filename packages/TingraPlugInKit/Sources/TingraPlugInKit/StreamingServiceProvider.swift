//
//  StreamingServiceProvider.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A stable identifier for a registered output, e.g. `rtmp`.
public struct OutputID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// What an output plug-in registers: a factory that creates a
/// ``StreamingService`` per stream for the destination URL schemes it
/// serves (see ARCHITECTURE.md, "The output registration seam").
///
/// A `StreamingService` is per-session state — one connection, one
/// timeline — so the registry holds providers, and the engine asks the
/// provider matching the destination's URL scheme for a fresh, configured
/// service each time a stream starts.
public protocol StreamingServiceProvider: Sendable {
    /// The provider's stable identifier.
    var id: OutputID { get }

    /// A short user-facing name, e.g. "RTMP Output".
    var name: String { get }

    /// The lowercase destination URL schemes this provider serves, e.g.
    /// `["rtmp", "rtmps"]`. The engine resolves a destination to a provider
    /// by scheme; one provider per scheme.
    var schemes: [String] { get }

    /// Creates a streaming service for one stream session, configured with
    /// the session's compression and program settings.
    ///
    /// - Parameter configuration: The session's stream configuration.
    /// - Returns: A fresh service; the caller owns its lifecycle
    ///   (``StreamingService/start(to:)`` through ``StreamingService/stop()``).
    func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService
}
