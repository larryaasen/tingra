//
//  InputRegistering.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The registration seam where input plug-ins attach: the host's input
/// registry, narrowed to the one thing a plug-in may do with it —
/// contribute inputs (see GLOSSARY.md, "Seam").
///
/// Defined here rather than in the host package so a plug-in can register
/// inputs without depending on the engine; the host's `InputRegistry`
/// conforms and arrives through ``PlugInContext/inputs``.
public protocol InputRegistering: Sendable {
    /// Registers an input contributed by a plug-in.
    ///
    /// Throws a descriptive error if the input cannot be accepted — for
    /// example, when its identifier is already registered.
    func register(_ input: any Input) async throws
}
