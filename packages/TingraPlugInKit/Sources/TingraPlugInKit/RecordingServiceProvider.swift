//
//  RecordingServiceProvider.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// What a recording plug-in registers: a factory that creates a
/// ``RecordingService`` per recording for the file extensions it serves
/// (see ARCHITECTURE.md, "The output registration seam" — recording joins
/// through the same seam as streaming output).
///
/// The recording counterpart to ``StreamingServiceProvider``: where a
/// streaming provider is keyed by destination URL scheme (`rtmp`/`rtmps`), a
/// recording provider is keyed by file extension (`mov`/`mp4`), because a
/// recording is resolved by the `--record <path>` target, not by a network
/// scheme. A ``RecordingService`` is per-recording state — one open file,
/// one timeline — so the registry holds providers and asks the provider
/// matching the target's extension for a fresh, configured service each time
/// a recording starts. Reuses the shared ``OutputID`` identifier type.
public protocol RecordingServiceProvider: Sendable {
    /// The provider's stable identifier.
    var id: OutputID { get }

    /// A short user-facing name, e.g. "Local Recording".
    var name: String { get }

    /// The lowercase file extensions this provider serves, e.g.
    /// `["mov", "mp4"]`. The engine resolves a `--record` target to a
    /// provider by extension; one provider per extension.
    var fileExtensions: [String] { get }

    /// Creates a recording service for one recording, configured with the
    /// program's compression settings.
    ///
    /// The program compression settings ``StreamConfiguration`` are shared
    /// with streaming: a compression session is configured per destination
    /// *or* recording (GLOSSARY.md, "Compression"), from the same option
    /// surface (CLI.md, "Compression").
    ///
    /// - Parameter configuration: The program's compression settings.
    /// - Returns: A fresh service; the caller owns its lifecycle
    ///   (``RecordingService/start(to:)`` through ``RecordingService/stop()``).
    func makeRecordingService(configuration: StreamConfiguration) -> any RecordingService
}
