//
//  DestinationTemplateMatchingTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraApp

/// The Streaming pane's template matching: which templates the URL field
/// suggests as it is typed, and which template a typed URL already is.
@Suite("Destination template matching")
struct DestinationTemplateMatchingTests {
    /// The first-party templates as the RTMP output declares them.
    private let templates: [DestinationTemplate] = [
        ("facebook", "Facebook Live", "rtmps://live-api-s.facebook.com:443/rtmp/"),
        ("twitch", "Twitch", "rtmp://live.twitch.tv/app"),
        ("youtube", "YouTube", "rtmps://a.rtmps.youtube.com/live2"),
    ].compactMap { id, name, url in
        URL(string: url).map { DestinationTemplate(id: id, name: name, url: $0) }
    }

    @Test("the fixture holds all three templates")
    func fixtureIsComplete() {
        #expect(templates.count == 3)
    }

    // MARK: - Matching a typed URL

    @Test(
        "a URL that reaches a template's destination matches it however it is spelled",
        arguments: [
            ("rtmp://live.twitch.tv/app", "twitch"),
            ("  rtmp://live.twitch.tv/app  ", "twitch"),
            ("rtmp://live.twitch.tv/app/", "twitch"),
            ("RTMP://Live.Twitch.TV/app", "twitch"),
            ("rtmp://live.twitch.tv:1935/app", "twitch"),
            ("rtmps://live-api-s.facebook.com:443/rtmp/", "facebook"),
            ("rtmps://live-api-s.facebook.com/rtmp", "facebook"),
            ("rtmps://a.rtmps.youtube.com:443/live2", "youtube"),
        ]
    )
    func matchesTemplate(text: String, expectedID: String) {
        #expect(templates.template(matchingURLText: text)?.id == expectedID)
    }

    @Test(
        "a URL that reaches anywhere else matches no template",
        arguments: [
            "",
            "tw",
            "rtmp://live.twitch.tv/apps",
            "rtmps://live.twitch.tv/app",
            "rtmp://live.twitch.tv:1936/app",
            "rtmp://a.rtmps.youtube.com/live2",
            "rtmps://a.rtmps.youtube.com/live2?backup=1",
            "srt://live.twitch.tv/app",
        ]
    )
    func matchesNothing(text: String) {
        #expect(templates.template(matchingURLText: text) == nil)
    }

    // MARK: - Suggestions

    @Test("a blank URL field suggests every template, in order")
    func blankSuggestsEverything() {
        #expect(templates.suggestions(forURLText: "").map(\.id) == ["facebook", "twitch", "youtube"])
        #expect(templates.suggestions(forURLText: "   ").map(\.id) == ["facebook", "twitch", "youtube"])
    }

    @Test(
        "typed text suggests each template whose name or URL contains it, ignoring case",
        arguments: [
            ("tw", ["twitch"]),
            ("TWI", ["twitch"]),
            ("you", ["youtube"]),
            ("rtmps", ["facebook", "youtube"]),
            ("rtmp", ["facebook", "twitch", "youtube"]),
            ("rtmp://", ["twitch"]),
            ("live", ["facebook", "twitch", "youtube"]),
            ("vimeo", []),
        ]
    )
    func typedTextFilters(text: String, expectedIDs: [String]) {
        #expect(templates.suggestions(forURLText: text).map(\.id) == expectedIDs)
    }

    @Test("a URL that already is a template suggests nothing, since there is nothing left to complete")
    func completeURLSuggestsNothing() {
        #expect(templates.suggestions(forURLText: "rtmp://live.twitch.tv/app").isEmpty)
        #expect(templates.suggestions(forURLText: "rtmps://live-api-s.facebook.com/rtmp").isEmpty)
    }

    @Test("with no templates registered nothing is suggested or matched")
    func noTemplates() {
        let none: [DestinationTemplate] = []
        #expect(none.suggestions(forURLText: "").isEmpty)
        #expect(none.suggestions(forURLText: "tw").isEmpty)
        #expect(none.template(matchingURLText: "rtmp://live.twitch.tv/app") == nil)
    }

    // MARK: - URL keys

    @Test("text without a scheme and a host has no URL key")
    func keyNeedsSchemeAndHost() {
        #expect(DestinationTemplateURLKey("live.twitch.tv/app") == nil)
        #expect(DestinationTemplateURLKey("rtmp://") == nil)
        #expect(DestinationTemplateURLKey("") == nil)
    }

    @Test("URL keys compare equal for one destination and unequal for another")
    func keyEquality() {
        #expect(
            DestinationTemplateURLKey("rtmps://host.example.com:443/app/")
                == DestinationTemplateURLKey("rtmps://HOST.example.com/app"))
        #expect(
            DestinationTemplateURLKey("rtmps://host.example.com/app")
                != DestinationTemplateURLKey("rtmp://host.example.com/app"))
        #expect(
            DestinationTemplateURLKey("srt://host.example.com:9000")
                != DestinationTemplateURLKey("srt://host.example.com"))
    }
}
