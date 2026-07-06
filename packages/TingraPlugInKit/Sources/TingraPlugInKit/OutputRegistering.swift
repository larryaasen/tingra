//
//  OutputRegistering.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The registration seam where output plug-ins attach: the host's output
/// registry, narrowed to the one thing a plug-in may do with it —
/// contribute streaming service providers (see GLOSSARY.md, "Seam", and
/// ARCHITECTURE.md, "The output registration seam").
///
/// Defined here rather than in the host package so a plug-in can register
/// outputs without depending on the engine; the host's `OutputRegistry`
/// conforms and arrives through ``PlugInContext/outputs``, mirroring
/// ``InputRegistering``.
///
/// Both streaming and recording outputs register here — multiple provider
/// kinds, one registry — because recording is an output sink parallel to
/// streaming (GLOSSARY.md, "Output": to destinations *or* to a recording),
/// resolved differently (by file extension, not URL scheme) but held by the
/// same host registry.
public protocol OutputRegistering: Sendable {
    /// Registers a streaming service provider contributed by a plug-in.
    ///
    /// Throws a descriptive error if the provider cannot be accepted — for
    /// example, when another provider already serves one of its URL schemes.
    func register(_ provider: any StreamingServiceProvider) async throws

    /// Registers a recording service provider contributed by a plug-in.
    ///
    /// Throws a descriptive error if the provider cannot be accepted — for
    /// example, when another provider already serves one of its file
    /// extensions.
    ///
    /// A pre-1.0 protocol addition (the seam gained recording alongside
    /// streaming at roadmap step 5), mirroring the ``InputRegistering``
    /// `unregister` addition; permitted during the 0.x CLI era before the
    /// external bundle loader ships (ARCHITECTURE.md, "Plug-in API stability
    /// and versioning").
    func register(_ provider: any RecordingServiceProvider) async throws
}
