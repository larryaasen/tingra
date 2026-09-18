//
//  RecordingFile.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where a recording is written: a local file URL and the container format
/// it is muxed into (see GLOSSARY.md, "Recording" — writing the program to
/// a local file, independent of streaming).
///
/// The recording counterpart to ``Destination``, deliberately kept
/// separate: recording has no stream key, no network host, and no
/// reconnect — a local file either writes or hits an I/O error. Reusing
/// ``Destination`` (URL + secret stream key) for a file path would carry a
/// meaningless secret and invite the streaming reconnect machinery onto a
/// sink that has no connection to lose.
public struct RecordingFile: Sendable, Equatable {
    /// The container format a recording is muxed into (CLI.md `--record`:
    /// `.mp4`/`.mov`).
    public enum Container: String, Sendable, Codable, CaseIterable {
        /// A QuickTime `.mov` container.
        case mov

        /// An MPEG-4 `.mp4` container.
        case mp4
    }

    /// The local file URL the program is written to.
    public let url: URL

    /// The container format, resolved from the path's extension.
    public let container: Container

    /// The values of the parameters the recording's provider declares
    /// (``RecordingServiceProvider`` through ``ParameterDescribing``), keyed
    /// by ``Parameter/key``; empty (the default) for a provider that
    /// declares none. Added 2026-09-15 (PLUGINS.md, Decision 15).
    public let parameters: [String: JSONValue]

    /// Creates a recording file target.
    ///
    /// - Parameters:
    ///   - url: The local file URL to write to.
    ///   - container: The container format to mux into.
    ///   - parameters: The provider's parameter values (default: none).
    public init(url: URL, container: Container, parameters: [String: JSONValue] = [:]) {
        self.url = url
        self.container = container
        self.parameters = parameters
    }
}
