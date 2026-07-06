//
//  IdentifiedError.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// An error that carries a stable ``ErrorIdentifier`` — the machine-readable
/// failure code the CLI's exit codes and the MCP tool errors both key off,
/// never the message wording (see CLI.md, "Error identifiers", and MCP.md,
/// "Errors that teach").
///
/// The engine's error enums (`StreamingServiceError`, `CaptureInputError`,
/// `InputSelectorError`, …) conform, so a front end can map any of them to
/// its identifier without knowing the concrete type — the MCP/Control
/// service relies on this to turn an error thrown from deep in the pipeline
/// into an identifier-keyed tool error, even for errors defined in a plug-in
/// package it does not import.
public protocol IdentifiedError: Error {
    /// The stable failure identifier for this error.
    var identifier: ErrorIdentifier { get }
}

/// The output seam's start errors carry their identifiers under the seam's
/// stability contract.
extension StreamingServiceError: IdentifiedError {}
