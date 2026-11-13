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
/// GLOSSARY.md's remaining input kind (network feed) joins as its plug-in
/// lands — a pre-1.0 addition permitted by the stability contract (see
/// ARCHITECTURE.md, "Plug-in API stability and versioning"), as `display`
/// did at roadmap step 6, `window` on 2026-10-08, and `application` on
/// 2026-11-11.
public enum InputKind: String, Sendable, Codable, CaseIterable {
    /// A camera device (built-in, external, or Continuity Camera).
    case camera

    /// A microphone device.
    case microphone

    /// A connected display, captured whole (a window is its own kind,
    /// ``window``, and an application's sound is ``application``). Not yet in the CLI's
    /// `devices` listing — display inputs are an app-era surface (CLI.md,
    /// "Non-goals (v1)").
    case display

    /// One window of a running application, captured alone wherever it
    /// sits — behind other windows or on another display. *Chosen*, not
    /// discovered: windows open and close all day, so a window input is
    /// made for the window the operator picks and registered by the host
    /// on the project's behalf, the way a media input is, never at plug-in
    /// activation (ARCHITECTURE.md, "Window capture"). An app-era surface
    /// like ``display``, so not in the CLI's `devices` listing.
    case window

    /// One running application's sound, captured alone — audio only, and
    /// kept off the Mac's speakers while it is captured unless the operator
    /// says otherwise. *Chosen*, not discovered, like ``window``: an input
    /// is made for the application the operator picks and registered by the
    /// host on the project's behalf, never at plug-in activation
    /// (ARCHITECTURE.md, "Application audio"). An app-era surface, so not
    /// in the CLI's `devices` listing.
    case application

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
    /// activation. A kind added after the plug-in API tags 1.0.0 breaks
    /// exhaustive switches in third-party code, so any kind later than
    /// that tag is a major (ARCHITECTURE.md, "Media inputs and the
    /// Library's Media tab").
    case media
}
