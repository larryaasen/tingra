//
//  InputKind.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The kind of input, driving grouping in discovery output (`tingra-cli
/// devices` sections, the `devices --json` keys) and selector resolution
/// (`--camera` only matches cameras).
///
/// GLOSSARY.md's remaining input kinds (display, window, application, media
/// file, network feed) join as their plug-ins land — a pre-1.0 addition
/// permitted by the stability contract (see ARCHITECTURE.md, "Plug-in API
/// stability and versioning").
public enum InputKind: String, Sendable, Codable, CaseIterable {
    /// A camera device (built-in, external, or Continuity Camera).
    case camera

    /// A microphone device.
    case microphone

    /// A generator: an input that synthesizes its content rather than
    /// capturing it (see GLOSSARY.md). Generators are selected by their
    /// stable identifiers (`--video-generator bars`, `--audio-generator
    /// tone`) and do not appear in the `devices` listing.
    case generator
}
