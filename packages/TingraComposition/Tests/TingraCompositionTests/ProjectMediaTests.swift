//
//  ProjectMediaTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraComposition

@Suite("Project media")
struct ProjectMediaTests {
    /// A sample item with a fixed identity, for round-trip coverage.
    private let sample = ProjectMedia(
        id: MediaID(rawValue: "media-1"), url: URL(filePath: "/Users/op/Pictures/poster.png"))

    @Test("A media identifier is fresh by default, round-trips through Codable, and doubles as the input identifier")
    func mediaIdentifier() throws {
        #expect(MediaID() != MediaID())
        let id = MediaID(rawValue: "media-1")
        let data = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(MediaID.self, from: data) == id)
        #expect(id.inputID == InputID(rawValue: "media-1"))
    }

    @Test("An item stores the file's absolute path and defaults its name to the file name")
    func itemDefaults() {
        #expect(sample.path == "/Users/op/Pictures/poster.png")
        #expect(sample.name == "poster.png")
        #expect(sample.url == URL(filePath: "/Users/op/Pictures/poster.png"))
        let named = ProjectMedia(url: URL(filePath: "/tmp/a.txt"), name: "Lower Third")
        #expect(named.name == "Lower Third")
    }

    @Test("An item round-trips through JSON with stable id, path, and name keys")
    func itemRoundTrips() throws {
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(ProjectMedia.self, from: data) == sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "path", "name"])
        #expect(object["id"] as? String == "media-1")
        #expect(object["path"] as? String == "/Users/op/Pictures/poster.png")
        #expect(object["name"] as? String == "poster.png")
    }

    @Test(
        "Decoding an item without a required key throws keyNotFound",
        arguments: [
            #"{"path":"/tmp/a.png","name":"a.png"}"#,
            #"{"id":"m","name":"a.png"}"#,
            #"{"id":"m","path":"/tmp/a.png"}"#,
        ]
    )
    func missingKeyThrows(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProjectMedia.self, from: Data(json.utf8))
        }
    }

    @Test("Items compare equal when matching and unequal when any field differs")
    func itemEquality() {
        #expect(
            sample
                == ProjectMedia(id: MediaID(rawValue: "media-1"), url: URL(filePath: "/Users/op/Pictures/poster.png")))
        #expect(
            sample
                != ProjectMedia(id: MediaID(rawValue: "media-2"), url: URL(filePath: "/Users/op/Pictures/poster.png")))
        #expect(
            sample != ProjectMedia(id: MediaID(rawValue: "media-1"), url: URL(filePath: "/Users/op/Pictures/other.png"))
        )
        #expect(
            sample
                != ProjectMedia(
                    id: MediaID(rawValue: "media-1"), url: URL(filePath: "/Users/op/Pictures/poster.png"),
                    name: "Poster"))
    }

    @Test("A project without the media key decodes with no media and encodes without the key")
    func projectMediaAbsent() throws {
        let decoded = try JSONDecoder().decode(Project.self, from: Data(#"{"version":1,"presets":[]}"#.utf8))
        #expect(decoded.media == nil)
        let data = try JSONEncoder().encode(Project())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["media"] == nil)
    }

    @Test("A project with media round-trips the list under the media key, in order")
    func projectMediaRoundTrips() throws {
        let second = ProjectMedia(id: MediaID(rawValue: "media-2"), url: URL(filePath: "/tmp/clip.mov"))
        let project = Project(media: [sample, second])
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.media?.map(\.id.rawValue) == ["media-1", "media-2"])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["media"] as? [Any])?.count == 2)
        #expect(Project(media: [sample]) != Project(media: nil))
    }
}
