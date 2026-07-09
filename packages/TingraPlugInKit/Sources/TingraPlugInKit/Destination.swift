//
//  Destination.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A configured target the program streams to: a streaming service ingest
/// point, a custom server, or a local endpoint (see GLOSSARY.md).
///
/// Deliberately not `Codable`: the stream key is a secret, and making this
/// type serializable invites writing it to disk by accident. Keys live in
/// the host's Keychain-backed secure storage and are referenced by a
/// redacted fingerprint (`live_xx…`) everywhere else (see EVENTS.md,
/// Redaction) — the key itself is never made an event param.
public struct Destination: Sendable {
    /// The RTMP(S) or SRT destination URL, e.g.
    /// `rtmp://live.twitch.tv/app` or `srt://host:8890?streamid=...`.
    public let url: URL

    /// The stream key, if the destination requires one. Never logged, never
    /// an event param, never returned by a tool.
    public let streamKey: String?

    /// Creates a destination from its URL and optional stream key.
    public init(url: URL, streamKey: String? = nil) {
        self.url = url
        self.streamKey = streamKey
    }
}
