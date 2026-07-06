//
//  ErrorIdentifier.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A stable, machine-readable identifier for a kind of failure.
///
/// Every `error` event carries one as its `identifier` param alongside a
/// human `message`; exit-code semantics map to identifiers, never to message
/// wording. The authoritative registry — each identifier's meaning and exit
/// code — lives in CLI.md ("Error identifiers"). Identifiers are
/// lowerCamelCase, bare (no dots), and **append-only: once shipped, never
/// renamed or reused** — they are a scripting and MCP contract, which is why
/// the constants live in this package under its API stability contract.
public struct ErrorIdentifier: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string, e.g. `"inputNotFound"`.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The registered identifiers (see CLI.md, "Error identifiers", for each
/// one's meaning and exit code).
extension ErrorIdentifier {
    /// An option value failed validation: malformed URL, bad resolution
    /// form, odd program dimensions, unparseable bitrate, conflicting flags.
    /// Exit code 64.
    public static let invalidArgument = ErrorIdentifier(rawValue: "invalidArgument")

    /// No registered input matches the selector, or no device of the
    /// required kind is connected to default to. Exit code 69.
    public static let inputNotFound = ErrorIdentifier(rawValue: "inputNotFound")

    /// A name-substring selector matches more than one input of that kind.
    /// Exit code 69.
    public static let inputAmbiguous = ErrorIdentifier(rawValue: "inputAmbiguous")

    /// Camera or microphone TCC authorization was denied. Exit code 69.
    public static let authorizationDenied = ErrorIdentifier(rawValue: "authorizationDenied")

    /// An internal pipeline error — a stage failed in a way that is not the
    /// caller's input or the network. Exit code 70.
    public static let pipelineError = ErrorIdentifier(rawValue: "pipelineError")

    /// The local recording could not be written — an unwritable path, a
    /// rejected format, or a write/finalize error (a full disk). Exit code
    /// 70. Distinct from `pipelineError` so scripts can tell a recording
    /// failure from a general stage failure.
    public static let recordingFailed = ErrorIdentifier(rawValue: "recordingFailed")

    /// The initial connection or handshake to the destination was rejected
    /// or unreachable. Exit code 75.
    public static let connectionFailed = ErrorIdentifier(rawValue: "connectionFailed")

    /// The connection dropped and was not recovered within the configured
    /// reconnect attempts. Exit code 75.
    public static let connectionLost = ErrorIdentifier(rawValue: "connectionLost")
}
