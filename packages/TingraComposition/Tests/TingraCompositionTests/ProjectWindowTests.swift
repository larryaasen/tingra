//
//  ProjectWindowTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraComposition

@Suite("Project windows")
struct ProjectWindowTests {
    /// A sample record with a fixed identity, for round-trip coverage.
    private let sample = ProjectWindow(
        id: InputID(rawValue: "window-1"),
        bundleIdentifier: "com.apple.Keynote",
        applicationName: "Keynote",
        title: "Launch Deck"
    )

    @Test("A record's identity is fresh by default")
    func freshIdentity() {
        let first = ProjectWindow(bundleIdentifier: "com.apple.Keynote", applicationName: "Keynote", title: "A")
        let second = ProjectWindow(bundleIdentifier: "com.apple.Keynote", applicationName: "Keynote", title: "A")
        #expect(first.id != second.id)
        #expect(first != second)
    }

    @Test("A record round-trips through JSON with stable id, bundleIdentifier, applicationName, and title keys")
    func recordRoundTrips() throws {
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(ProjectWindow.self, from: data) == sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "bundleIdentifier", "applicationName", "title"])
        #expect(object["id"] as? String == "window-1")
        #expect(object["bundleIdentifier"] as? String == "com.apple.Keynote")
        #expect(object["applicationName"] as? String == "Keynote")
        #expect(object["title"] as? String == "Launch Deck")
    }

    @Test(
        "Decoding a record without a required key throws keyNotFound",
        arguments: [
            #"{"bundleIdentifier":"com.apple.Keynote","applicationName":"Keynote","title":"Deck"}"#,
            #"{"id":"w","applicationName":"Keynote","title":"Deck"}"#,
            #"{"id":"w","bundleIdentifier":"com.apple.Keynote","title":"Deck"}"#,
            #"{"id":"w","bundleIdentifier":"com.apple.Keynote","applicationName":"Keynote"}"#,
        ]
    )
    func missingKeyThrows(json: String) {
        #expect {
            try JSONDecoder().decode(ProjectWindow.self, from: Data(json.utf8))
        } throws: { error in
            guard case DecodingError.keyNotFound = error else { return false }
            return true
        }
    }

    @Test("Records compare equal when matching and unequal when any field differs")
    func recordEquality() {
        func record(
            id: String = "window-1",
            bundle: String = "com.apple.Keynote",
            application: String = "Keynote",
            title: String = "Launch Deck"
        ) -> ProjectWindow {
            ProjectWindow(
                id: InputID(rawValue: id), bundleIdentifier: bundle, applicationName: application, title: title)
        }
        #expect(sample == record())
        #expect(sample != record(id: "window-2"))
        #expect(sample != record(bundle: "com.apple.finder"))
        #expect(sample != record(application: "Finder"))
        #expect(sample != record(title: "Budget"))
    }

    @Test("A project without the windows key decodes with no windows and encodes without the key")
    func projectWindowsAbsent() throws {
        let decoded = try JSONDecoder().decode(Project.self, from: Data(#"{"version":1,"presets":[]}"#.utf8))
        #expect(decoded.windows == nil)
        let data = try JSONEncoder().encode(Project())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["windows"] == nil)
    }

    @Test("A project with windows round-trips the list under the windows key, in order")
    func projectWindowsRoundTrip() throws {
        let second = ProjectWindow(
            id: InputID(rawValue: "window-2"),
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            title: "Apple"
        )
        let project = Project(windows: [sample, second])
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.windows?.map(\.id.rawValue) == ["window-1", "window-2"])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["windows"] as? [Any])?.count == 2)
        #expect(Project(windows: [sample]) != Project(windows: nil))
    }
}
