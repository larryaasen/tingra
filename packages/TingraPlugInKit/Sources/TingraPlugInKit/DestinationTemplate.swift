//
//  DestinationTemplate.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A well-known destination a new one can start from: a service's name, its
/// published URL, and the page where the operator finds its stream key
/// (DESTINATIONS.md, "Destination templates"; GLOSSARY.md, "Destination
/// template").
///
/// A streaming provider contributes the templates it can stream to
/// (``StreamingServiceProvider/destinationTemplates``), and a host offers
/// them when a destination is added or its URL is typed. A template is not a
/// destination: picking one adds an ordinary destination with the name and
/// URL filled in, which keeps no link back to the template — so a later
/// release changing a template touches nothing already saved.
///
/// Only a service with **one URL for every account** has a template. A
/// service that hands each account or each broadcast its own URL is added as
/// a custom server instead.
public struct DestinationTemplate: Sendable, Hashable {
    /// The template's stable lowercase identifier within its provider, e.g.
    /// `twitch` — what a host names it by in an event param.
    public let id: String

    /// The service's name, e.g. "Twitch" — a proper noun, shown as given in
    /// every language, and the name a destination made from it starts with.
    public let name: String

    /// The URL the service publishes for streaming to it, e.g.
    /// `rtmp://live.twitch.tv/app`. Its scheme must be one the contributing
    /// provider serves; a host rejects the provider at registration
    /// otherwise.
    public let url: URL

    /// The web page where the operator finds the service's stream key, or
    /// nil when the service has no single page for it.
    public let streamKeyPageURL: URL?

    /// Creates a template.
    ///
    /// - Parameters:
    ///   - id: The stable lowercase identifier, unique within the provider.
    ///   - name: The service's name.
    ///   - url: The URL the service publishes for streaming to it.
    ///   - streamKeyPageURL: The page where the stream key is found
    ///     (default none).
    public init(id: String, name: String, url: URL, streamKeyPageURL: URL? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.streamKeyPageURL = streamKeyPageURL
    }
}
