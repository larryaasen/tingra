//
//  DestinationEditTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition

@testable import TingraApp

/// The streaming panel's destination editing: which typed URLs become
/// streamable legs, which reach the saved document, and how a destination
/// keeps its identity (and therefore its stored stream key) across an edit.
@Suite("DestinationEdit")
struct DestinationEditTests {
    @Test(
        "a supported, complete URL is streamable",
        arguments: [
            "rtmp://live.twitch.tv/app",
            "rtmps://a.rtmps.youtube.com/live2",
            "srt://ingest.example.com:8890",
            "  rtmp://live.twitch.tv/app  ",
        ]
    )
    func supportedURLsAreStreamable(text: String) {
        let destination = DestinationEdit(urlText: text)
        #expect(destination.url != nil)
        #expect(destination.isStreamable)
    }

    @Test(
        "a partial, empty, or unsupported URL is not streamable",
        arguments: ["", "   ", "rtm", "rtmp://", "http://example.com", "live.twitch.tv/app"]
    )
    func unusableURLsAreNotStreamable(text: String) {
        // `URL(string:)` accepts almost any fragment, so a scheme and host
        // check is what keeps a half-typed URL out of the destination list.
        let destination = DestinationEdit(urlText: text)
        #expect(destination.url == nil)
        #expect(!destination.isStreamable)
        #expect(destination.projectDestination == nil)
    }

    @Test("a disabled destination has a URL but contributes no leg")
    func disabledDestinationIsNotStreamable() {
        let destination = DestinationEdit(urlText: "rtmp://live.twitch.tv/app", isEnabled: false)
        #expect(destination.url != nil)
        #expect(!destination.isStreamable)
        // It still saves: disabling parks a destination, it does not discard it.
        #expect(destination.projectDestination?.isEnabled == false)
    }

    @Test("the document record carries the id, trimmed URL, name, and enabled flag")
    func projectDestinationCarriesEveryField() throws {
        let id = ProjectDestinationID(rawValue: "d1")
        let destination = DestinationEdit(id: id, urlText: "rtmp://live.twitch.tv/app", name: "Twitch")
        let record = try #require(destination.projectDestination)

        #expect(record.id == id)
        #expect(record.url.absoluteString == "rtmp://live.twitch.tv/app")
        #expect(record.name == "Twitch")
        #expect(record.isEnabled)
    }

    @Test("editing the URL keeps the destination's id, so its stored key follows the edit")
    func editingTheURLKeepsTheIdentity() throws {
        var destination = DestinationEdit(urlText: "rtmp://old.example/app", name: "Twitch")
        let originalID = destination.id

        destination.urlText = "rtmp://new.example/app"

        #expect(destination.id == originalID)
        #expect(try #require(destination.projectDestination).id == originalID)
    }

    @Test("adopting a saved destination round-trips every field")
    func adoptingASavedDestinationRoundTrips() throws {
        let saved = ProjectDestination(
            id: ProjectDestinationID(rawValue: "d1"),
            url: try #require(URL(string: "srt://backup.example:8890")),
            name: "Backup",
            isEnabled: false
        )
        let destination = DestinationEdit(saved)

        #expect(destination.id == saved.id)
        #expect(destination.urlText == "srt://backup.example:8890")
        #expect(destination.name == "Backup")
        #expect(!destination.isEnabled)
        #expect(destination.projectDestination == saved)
    }

    @Test("the panel's destinations become the saved list in order, skipping unusable rows")
    func savedListSkipsUnusableRows() throws {
        let edits = [
            DestinationEdit(id: ProjectDestinationID(rawValue: "d1"), urlText: "rtmp://a.example/app", name: "A"),
            // A row the operator added but has not filled in yet.
            DestinationEdit(id: ProjectDestinationID(rawValue: "d2"), urlText: "rtm"),
            DestinationEdit(id: ProjectDestinationID(rawValue: "d3"), urlText: "srt://c.example:8890", name: "C"),
        ]
        let saved = try #require(DestinationEdit.projectDestinations(from: edits))

        #expect(saved.count == 2)
        #expect(saved[0].name == "A")
        #expect(saved[1].name == "C")
    }

    @Test("a panel with no usable destination saves no list at all")
    func noUsableDestinationSavesNothing() {
        #expect(DestinationEdit.projectDestinations(from: []) == nil)
        #expect(DestinationEdit.projectDestinations(from: [DestinationEdit()]) == nil)
    }

    @Test("the saved list and the panel's rows round-trip through each other")
    func editsAndRecordsRoundTrip() throws {
        let records = [
            ProjectDestination(
                id: ProjectDestinationID(rawValue: "d1"),
                url: try #require(URL(string: "rtmp://a.example/app")),
                name: "A"
            ),
            ProjectDestination(
                id: ProjectDestinationID(rawValue: "d2"),
                url: try #require(URL(string: "srt://b.example:8890")),
                name: "B",
                isEnabled: false
            ),
        ]
        let edits = DestinationEdit.edits(from: records)

        #expect(edits.count == 2)
        #expect(DestinationEdit.projectDestinations(from: edits) == records)
    }

    @Test("an absent saved list produces no rows")
    func absentSavedListProducesNoRows() {
        #expect(DestinationEdit.edits(from: nil).isEmpty)
    }

    @Test("the row label prefers the name, then the URL, then a placeholder")
    func displayNamePrefersTheName() {
        #expect(DestinationEdit(urlText: "rtmp://a.example/app", name: "Twitch").displayName == "Twitch")
        #expect(DestinationEdit(urlText: "rtmp://a.example/app").displayName == "rtmp://a.example/app")
        #expect(DestinationEdit(urlText: "  ", name: "  ").displayName == "New destination")
    }

    @Test("destinations are equal only when every field matches")
    func destinationEditEquality() {
        let id = ProjectDestinationID(rawValue: "d1")
        let base = DestinationEdit(id: id, urlText: "rtmp://a.example/app", name: "A")

        #expect(base == DestinationEdit(id: id, urlText: "rtmp://a.example/app", name: "A"))
        #expect(base != DestinationEdit(id: id, urlText: "rtmp://b.example/app", name: "A"))
        #expect(base != DestinationEdit(id: id, urlText: "rtmp://a.example/app", name: "B"))
        #expect(base != DestinationEdit(id: id, urlText: "rtmp://a.example/app", name: "A", isEnabled: false))
        #expect(base != DestinationEdit(urlText: "rtmp://a.example/app", name: "A"))
    }
}
