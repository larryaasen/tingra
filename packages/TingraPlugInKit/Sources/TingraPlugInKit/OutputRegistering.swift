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
public protocol OutputRegistering: Sendable {
    /// Registers a streaming service provider contributed by a plug-in.
    ///
    /// Throws a descriptive error if the provider cannot be accepted — for
    /// example, when another provider already serves one of its URL schemes.
    func register(_ provider: any StreamingServiceProvider) async throws
}
