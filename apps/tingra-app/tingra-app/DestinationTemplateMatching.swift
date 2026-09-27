//
//  DestinationTemplateMatching.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// How the Streaming settings pane relates typed URL text to the destination
/// templates the output plug-ins offer (DESTINATIONS.md, "What the app does
/// with it"): which templates the URL field suggests as it is typed, and
/// which template — if any — a typed URL already is.
///
/// Its own file of pure functions rather than logic in the view, for the
/// reason every decision in this app gets a testable home: "is this pasted
/// URL Facebook Live?" has edge cases (a trailing slash, an explicit default
/// port, capitals in the host) that a view cannot be tested against.
extension Array where Element == DestinationTemplate {
    /// The templates the URL field suggests for the text typed so far.
    ///
    /// Every template while the field is blank, since a blank URL is exactly
    /// when the operator most needs one; none once the text already is a
    /// template's URL, since there is nothing left to complete; otherwise
    /// each template whose name or URL contains the text, matched with
    /// `localizedStandardContains` so "tw" finds Twitch and "youtube" finds
    /// its URL. Order is kept, so suggestions list in the menu's order.
    ///
    /// - Parameter text: The URL field's text as typed.
    /// - Returns: The templates to suggest.
    func suggestions(forURLText text: String) -> [DestinationTemplate] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return self }
        guard template(matchingURLText: typed) == nil else { return [] }
        return filter {
            $0.name.localizedStandardContains(typed) || $0.url.absoluteString.localizedStandardContains(typed)
        }
    }

    /// The template whose URL the typed text is, or nil when it is none of
    /// them.
    ///
    /// Two URLs match when they reach the same place: the scheme and host
    /// compare without regard to case, a port that is the scheme's default is
    /// the same as no port, and trailing slashes on the path are ignored — so
    /// Facebook's documented `rtmps://live-api-s.facebook.com:443/rtmp/` and
    /// a pasted `rtmps://live-api-s.facebook.com/rtmp` are one destination.
    ///
    /// - Parameter text: The URL field's text as typed.
    /// - Returns: The matching template, or nil.
    func template(matchingURLText text: String) -> DestinationTemplate? {
        guard let typed = DestinationTemplateURLKey(text) else { return nil }
        return first { DestinationTemplateURLKey($0.url.absoluteString) == typed }
    }
}

/// A URL reduced to what decides where it streams to, so two spellings of
/// one destination compare equal (see
/// ``Swift/Array/template(matchingURLText:)``).
struct DestinationTemplateURLKey: Equatable {
    /// The lowercased scheme.
    let scheme: String

    /// The lowercased host.
    let host: String

    /// The port, or nil when none was given or it is the scheme's default.
    let port: Int?

    /// The path without trailing slashes.
    let path: String

    /// The query, compared as written.
    let query: String?

    /// The default port of each streaming scheme that has one — what an
    /// explicit `:443` on an `rtmps://` URL is equivalent to leaving out.
    private static let defaultPorts = ["rtmp": 1935, "rtmps": 443]

    /// Reduces URL text to its key, or returns nil for text that is not a
    /// URL with a scheme and a host.
    ///
    /// - Parameter text: The URL as typed or as a template writes it.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = components.port == Self.defaultPorts[scheme] ? nil : components.port
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        self.path = path
        self.query = components.query
    }
}
