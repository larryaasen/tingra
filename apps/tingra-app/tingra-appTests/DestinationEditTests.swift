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
import TingraHost

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
        #expect(destination.storedDestination == nil)
    }

    @Test("a disabled destination has a URL but contributes no leg")
    func disabledDestinationIsNotStreamable() {
        let destination = DestinationEdit(urlText: "rtmp://live.twitch.tv/app", isEnabled: false)
        #expect(destination.url != nil)
        #expect(!destination.isStreamable)
        // It still references: disabling parks a destination for this show, it
        // does not discard the operator's saved record.
        #expect(destination.reference.isEnabled == false)
        #expect(destination.storedDestination != nil)
    }

    @Test("the stored record carries the id, trimmed URL, and name — and no enabled flag")
    func storedDestinationCarriesEveryField() throws {
        let id = ProjectDestinationID(rawValue: "d1")
        let destination = DestinationEdit(id: id, urlText: "rtmp://live.twitch.tv/app", name: "Twitch")
        let record = try #require(destination.storedDestination)

        #expect(record.id.rawValue == id.rawValue)
        #expect(record.url.absoluteString == "rtmp://live.twitch.tv/app")
        #expect(record.name == "Twitch")
    }

    @Test("the project reference carries the id and the enabled flag, and nothing else")
    func referenceCarriesPerShowState() {
        let id = ProjectDestinationID(rawValue: "d1")
        let destination = DestinationEdit(id: id, urlText: "rtmp://a.example/app", isEnabled: false)

        #expect(destination.reference == DestinationReference(id: id, isEnabled: false))
    }

    @Test("a row with no usable URL still references, so parking a half-typed row is remembered")
    func unusableRowStillReferences() {
        let destination = DestinationEdit(id: ProjectDestinationID(rawValue: "d1"), urlText: "rtm")
        #expect(destination.storedDestination == nil)
        #expect(destination.reference.id.rawValue == "d1")
    }

    @Test("editing the URL keeps the destination's id, so its stored key follows the edit")
    func editingTheURLKeepsTheIdentity() throws {
        var destination = DestinationEdit(urlText: "rtmp://old.example/app", name: "Twitch")
        let originalID = destination.id

        destination.urlText = "rtmp://new.example/app"

        #expect(destination.id == originalID)
        #expect(try #require(destination.storedDestination).id.rawValue == originalID.rawValue)
    }

    @Test("adopting a saved destination round-trips every field")
    func adoptingASavedDestinationRoundTrips() throws {
        let saved = StoredDestination(
            id: DestinationID(rawValue: "d1"),
            name: "Backup",
            url: try #require(URL(string: "srt://backup.example:8890"))
        )
        let destination = DestinationEdit(saved, isEnabled: false)

        #expect(destination.id.rawValue == "d1")
        #expect(destination.urlText == "srt://backup.example:8890")
        #expect(destination.name == "Backup")
        #expect(!destination.isEnabled)
        #expect(destination.storedDestination == saved)
    }

    /// A saved destination with a fixed id, so merges compare exactly.
    private func makeSaved(_ id: String, _ url: String, name: String = "") throws -> StoredDestination {
        StoredDestination(id: DestinationID(rawValue: id), name: name, url: try #require(URL(string: url)))
    }

    @Test("the panel lists every saved destination in store order, carrying this project's enabled flags")
    func mergeListsTheStoreInOrder() throws {
        let saved = [
            try makeSaved("d1", "rtmp://a.example/app", name: "A"),
            try makeSaved("d2", "srt://b.example:8890", name: "B"),
        ]
        let references = [
            DestinationReference(id: ProjectDestinationID(rawValue: "d2"), isEnabled: false),
            DestinationReference(id: ProjectDestinationID(rawValue: "d1"), isEnabled: true),
        ]
        let edits = DestinationEdit.edits(saved: saved, references: references)

        // Store order, not reference order — the list is operator-global.
        #expect(edits.map(\.name) == ["A", "B"])
        #expect(edits[0].isEnabled)
        #expect(!edits[1].isEnabled)
    }

    @Test("a destination this project has never referenced is listed but not enabled")
    func unreferencedDestinationIsOffered() throws {
        let saved = [try makeSaved("d1", "rtmp://a.example/app", name: "A")]
        let edits = DestinationEdit.edits(saved: saved, references: nil)

        #expect(edits.count == 1)
        // Offered, never surprise-live: another show's destination does not
        // start streaming here just by existing.
        #expect(!edits[0].isEnabled)
    }

    @Test("a reference naming a destination the operator deleted contributes no row")
    func danglingReferenceIsDropped() throws {
        let saved = [try makeSaved("d1", "rtmp://a.example/app", name: "A")]
        let references = [
            DestinationReference(id: ProjectDestinationID(rawValue: "d1")),
            DestinationReference(id: ProjectDestinationID(rawValue: "gone")),
        ]
        let edits = DestinationEdit.edits(saved: saved, references: references)

        #expect(edits.count == 1)
        #expect(edits[0].id.rawValue == "d1")
    }

    @Test("an empty store produces no rows, whatever the project references")
    func emptyStoreProducesNoRows() {
        let references = [DestinationReference(id: ProjectDestinationID(rawValue: "d1"))]
        #expect(DestinationEdit.edits(saved: [], references: references).isEmpty)
        #expect(DestinationEdit.edits(saved: [], references: nil).isEmpty)
    }

    @Test("every row becomes a reference, parked ones included")
    func everyRowReferences() throws {
        let edits = [
            DestinationEdit(id: ProjectDestinationID(rawValue: "d1"), urlText: "rtmp://a.example/app"),
            DestinationEdit(id: ProjectDestinationID(rawValue: "d2"), urlText: "rtm", isEnabled: false),
        ]
        let references = try #require(DestinationEdit.references(from: edits))

        #expect(references.count == 2)
        #expect(references[0].isEnabled)
        #expect(!references[1].isEnabled)
    }

    @Test("a panel with no rows references nothing at all")
    func noRowsReferenceNothing() {
        #expect(DestinationEdit.references(from: []) == nil)
    }

    @Test("the store's records and the panel's rows round-trip through each other")
    func editsAndRecordsRoundTrip() throws {
        let saved = [
            try makeSaved("d1", "rtmp://a.example/app", name: "A"),
            try makeSaved("d2", "srt://b.example:8890", name: "B"),
        ]
        let edits = DestinationEdit.edits(saved: saved, references: DestinationEdit.references(from: []))

        #expect(edits.count == 2)
        #expect(edits.compactMap(\.storedDestination) == saved)
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
