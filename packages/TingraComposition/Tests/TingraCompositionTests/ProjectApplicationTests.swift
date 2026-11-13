//
//  ProjectApplicationTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraComposition

@Suite("Project applications")
struct ProjectApplicationTests {
    /// A sample record with a fixed identity, for round-trip coverage.
    private let sample = ProjectApplication(
        id: InputID(rawValue: "application-1"),
        bundleIdentifier: "com.apple.Music",
        name: "Music"
    )

    @Test("A record's identity is fresh by default")
    func freshIdentity() {
        let first = ProjectApplication(bundleIdentifier: "com.apple.Music", name: "Music")
        let second = ProjectApplication(bundleIdentifier: "com.apple.Music", name: "Music")
        #expect(first.id != second.id)
        #expect(first != second)
    }

    @Test("A record round-trips through JSON with stable id, bundleIdentifier, and name keys")
    func recordRoundTrips() throws {
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(ProjectApplication.self, from: data) == sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "bundleIdentifier", "name"])
        #expect(object["id"] as? String == "application-1")
        #expect(object["bundleIdentifier"] as? String == "com.apple.Music")
        #expect(object["name"] as? String == "Music")
    }

    @Test(
        "Decoding a record without a required key throws keyNotFound",
        arguments: [
            #"{"bundleIdentifier":"com.apple.Music","name":"Music"}"#,
            #"{"id":"a","name":"Music"}"#,
            #"{"id":"a","bundleIdentifier":"com.apple.Music"}"#,
        ]
    )
    func missingKeyThrows(json: String) {
        #expect {
            try JSONDecoder().decode(ProjectApplication.self, from: Data(json.utf8))
        } throws: { error in
            guard case DecodingError.keyNotFound = error else { return false }
            return true
        }
    }

    @Test("Records compare equal when matching and unequal when any field differs")
    func recordEquality() {
        func record(
            id: String = "application-1", bundle: String = "com.apple.Music", name: String = "Music"
        ) -> ProjectApplication {
            ProjectApplication(id: InputID(rawValue: id), bundleIdentifier: bundle, name: name)
        }
        #expect(sample == record())
        #expect(sample != record(id: "application-2"))
        #expect(sample != record(bundle: "com.apple.Podcasts"))
        #expect(sample != record(name: "Podcasts"))
    }

    @Test("A project without the applications key decodes with none and encodes without the key")
    func projectApplicationsAbsent() throws {
        let decoded = try JSONDecoder().decode(Project.self, from: Data(#"{"version":1,"presets":[]}"#.utf8))
        #expect(decoded.applications == nil)
        let data = try JSONEncoder().encode(Project())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["applications"] == nil)
    }

    @Test("A project with applications round-trips the list under the applications key, in order")
    func projectApplicationsRoundTrip() throws {
        let second = ProjectApplication(
            id: InputID(rawValue: "application-2"), bundleIdentifier: "com.apple.Podcasts", name: "Podcasts")
        let project = Project(applications: [sample, second])
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.applications?.map(\.id.rawValue) == ["application-1", "application-2"])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["applications"] as? [Any])?.count == 2)
        #expect(Project(applications: [sample]) != Project(applications: nil))
    }
}
