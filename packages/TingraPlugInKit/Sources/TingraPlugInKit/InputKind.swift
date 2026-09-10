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
/// GLOSSARY.md's remaining input kinds (window, application, media file,
/// network feed) join as their plug-ins land — a pre-1.0 addition permitted
/// by the stability contract (see ARCHITECTURE.md, "Plug-in API stability
/// and versioning"), as `display` did at roadmap step 6.
public enum InputKind: String, Sendable, Codable, CaseIterable {
    /// A camera device (built-in, external, or Continuity Camera).
    case camera

    /// A microphone device.
    case microphone

    /// A connected display, captured whole (window and application inputs
    /// are separate kinds, arriving later). Not yet in the CLI's `devices`
    /// listing — display inputs are an app-era surface (CLI.md, "Non-goals
    /// (v1)").
    case display

    /// A generator: an input that synthesizes its content rather than
    /// capturing it (see GLOSSARY.md). Generators are selected by their
    /// stable identifiers (`--video-generator bars`, `--audio-generator
    /// tone`) and do not appear in the `devices` listing.
    case generator

    /// Media: an input whose content comes from a file the operator added
    /// to the project — a still image, a video file, a text or Markdown
    /// document (see GLOSSARY.md). Added rather than discovered, so media
    /// inputs are created by a ``MediaInputProvider`` for a given file and
    /// registered by the host on the project's behalf, never at plug-in
    /// activation. The last kind added before the plug-in API tags 1.0.0:
    /// a new case breaks exhaustive switches in third-party code, so any
    /// later kind is a major (ARCHITECTURE.md, "Media inputs and the
    /// Library's Media tab").
    case media
}
