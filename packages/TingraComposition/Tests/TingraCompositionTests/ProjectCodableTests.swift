//
//  ProjectCodableTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraComposition

/// Verifies the persisted project document contract: `Project` round-trips
/// through JSON exactly, keeps stable keys, requires its format version, and
/// refuses a document newer than this build understands (CLAUDE.md, "Data
/// Models"; ARCHITECTURE.md, "Project save/load").
@Suite("Project persistence")
struct ProjectCodableTests {
    /// A project with one preset holding one single-layer shot, for
    /// round-trip coverage.
    private var sampleProject: Project {
        Project(
            presets: [
                Preset(
                    id: PresetID(rawValue: "preset-1"),
                    name: "Live",
                    shots: [
                        Shot(
                            id: ShotID(rawValue: "display"), name: "Display",
                            layers: [Layer(input: InputID(rawValue: "display-1"))])
                    ]
                )
            ]
        )
    }

    @Test("a project round-trips through JSON unchanged")
    func projectRoundTrips() throws {
        let data = try JSONEncoder().encode(sampleProject)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == sampleProject)
    }

    @Test("a project encodes stable version and presets keys")
    func projectKeysAreStable() throws {
        let data = try JSONEncoder().encode(sampleProject)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == Project.currentVersion)
        #expect((object["presets"] as? [Any])?.count == 1)
        #expect(Set(object.keys) == ["version", "presets"])
    }

    @Test("decoding a project without a version throws a keyNotFound error")
    func projectMissingVersionThrows() throws {
        let json = Data(#"{"presets":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Project.self, from: json)
        }
    }

    @Test("decoding a project newer than this build understands throws a dataCorrupted error")
    func projectNewerVersionThrows() throws {
        let json = Data(#"{"version":\#(Project.currentVersion + 1),"presets":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Project.self, from: json)
        }
    }

    @Test("a project with no presets key decodes to an empty preset list")
    func projectOptionalPresetsDefaults() throws {
        let json = Data(#"{"version":1}"#.utf8)
        let decoded = try JSONDecoder().decode(Project.self, from: json)
        #expect(decoded.version == 1)
        #expect(decoded.presets.isEmpty)
    }

    @Test("a project defaults to the current version and no presets")
    func projectDefaults() {
        let project = Project()
        #expect(project.version == Project.currentVersion)
        #expect(project.presets.isEmpty)
    }

    @Test("projects are equal only when their version, presets, and destinations all match")
    func projectEquality() throws {
        let preset = Preset(id: PresetID(rawValue: "p"), name: "Live")
        let destination = ProjectDestination(url: try #require(URL(string: "rtmp://live.example/app")))
        let base = Project(presets: [preset])
        let same = Project(presets: [preset])
        let otherVersion = Project(version: 0, presets: [preset])
        let otherPresets = Project(presets: [])
        let withDestination = Project(presets: [preset], destinations: [destination])
        #expect(base == same)
        #expect(base != otherVersion)
        #expect(base != otherPresets)
        #expect(base != withDestination)
    }

    // MARK: Destinations

    @Test("the document format version is 1 — pre-release, the format grows within v1")
    func currentVersionIsOne() {
        #expect(Project.currentVersion == 1)
    }

    /// A destination with a fixed id, so encoded documents compare exactly.
    private func makeDestination(
        _ url: String,
        id: String = "d1",
        name: String = "",
        isEnabled: Bool = true
    ) throws -> ProjectDestination {
        ProjectDestination(
            id: ProjectDestinationID(rawValue: id),
            url: try #require(URL(string: url)),
            name: name,
            isEnabled: isEnabled
        )
    }

    @Test("a project with a destination round-trips through JSON unchanged")
    func projectWithDestinationRoundTrips() throws {
        let project = Project(
            presets: sampleProject.presets,
            destinations: [try makeDestination("rtmp://live.twitch.tv/app", name: "Twitch")]
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.destinations?.first?.url.absoluteString == "rtmp://live.twitch.tv/app")
        #expect(decoded.destinations?.first?.name == "Twitch")
    }

    @Test("several destinations round-trip in order with their ids, names, and enabled flags")
    func severalDestinationsRoundTrip() throws {
        let project = Project(
            presets: sampleProject.presets,
            destinations: [
                try makeDestination("rtmp://live.twitch.tv/app", id: "d1", name: "Twitch"),
                try makeDestination("srt://backup.example:8890", id: "d2", name: "Backup", isEnabled: false),
            ]
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        #expect(decoded == project)
        #expect(decoded.destinations?.count == 2)
        #expect(decoded.destinations?[0].id == ProjectDestinationID(rawValue: "d1"))
        #expect(decoded.destinations?[0].isEnabled == true)
        #expect(decoded.destinations?[1].id == ProjectDestinationID(rawValue: "d2"))
        #expect(decoded.destinations?[1].isEnabled == false)
        #expect(decoded.destinations?[1].url.absoluteString == "srt://backup.example:8890")
    }

    @Test("a project with destinations encodes version, presets, and destinations keys")
    func projectWithDestinationKeys() throws {
        let project = Project(
            presets: sampleProject.presets,
            destinations: [try makeDestination("rtmp://live.twitch.tv/app")]
        )
        let data = try JSONEncoder().encode(project)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The superseded single `destination` key is never written again.
        #expect(Set(object.keys) == ["version", "presets", "destinations"])
    }

    @Test("a document without a destinations key decodes with destinations nil")
    func missingDestinationDecodesNil() throws {
        let json = Data(#"{"version":1,"presets":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(Project.self, from: json)
        #expect(decoded.version == 1)
        #expect(decoded.destinations == nil)
    }

    @Test("a document written with the single destination key folds it in as the only destination")
    func singleDestinationKeyFoldsIn() throws {
        // The shape written before a project could hold several — it must
        // still open, with the destination becoming the first (and only) one.
        let json = Data(#"{"version":1,"presets":[],"destination":{"url":"rtmp://live.twitch.tv/app"}}"#.utf8)
        let decoded = try JSONDecoder().decode(Project.self, from: json)

        #expect(decoded.destinations?.count == 1)
        #expect(decoded.destinations?.first?.url.absoluteString == "rtmp://live.twitch.tv/app")
        // The keyless older shape gains an identity and streams by default.
        #expect(decoded.destinations?.first?.name == "")
        #expect(decoded.destinations?.first?.isEnabled == true)
        #expect(decoded.destinations?.first?.id.rawValue.isEmpty == false)
    }

    @Test("the destinations list wins when a document carries both keys")
    func destinationsListWinsOverTheSingleKey() throws {
        let json = Data(
            #"""
            {"version":1,"presets":[],"destination":{"url":"rtmp://old.example/app"},\#
            "destinations":[{"id":"d1","url":"rtmp://new.example/app","name":"New","isEnabled":true}]}
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(Project.self, from: json)

        #expect(decoded.destinations?.count == 1)
        #expect(decoded.destinations?.first?.url.absoluteString == "rtmp://new.example/app")
    }

    @Test("a destination without a url returns a decoding error")
    func destinationWithoutURLThrows() throws {
        let json = Data(#"{"version":1,"presets":[],"destinations":[{"name":"Twitch"}]}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Project.self, from: json)
        }
    }

    @Test("destinations are equal only when every field matches")
    func destinationEquality() throws {
        let base = try makeDestination("rtmp://live.example/app", id: "d1", name: "Twitch")
        #expect(base == (try makeDestination("rtmp://live.example/app", id: "d1", name: "Twitch")))
        #expect(base != (try makeDestination("rtmp://other.example/app", id: "d1", name: "Twitch")))
        #expect(base != (try makeDestination("rtmp://live.example/app", id: "d2", name: "Twitch")))
        #expect(base != (try makeDestination("rtmp://live.example/app", id: "d1", name: "YouTube")))
        #expect(base != (try makeDestination("rtmp://live.example/app", id: "d1", name: "Twitch", isEnabled: false)))
    }

    // MARK: Default transitions

    @Test("a document whose shots have no defaultTransition keys decodes with no defaults")
    func missingDefaultTransitionsDecodeNil() throws {
        let json = Data(
            #"{"version":1,"presets":[{"id":"p","name":"Live","shots":[{"id":"s","name":"Wide"}]}]}"#.utf8)
        let decoded = try JSONDecoder().decode(Project.self, from: json)
        #expect(decoded.version == 1)
        #expect(decoded.presets.first?.shots.first?.defaultTransition == nil)
    }

    @Test("a project whose shot carries a default transition round-trips through JSON unchanged")
    func projectWithDefaultTransitionRoundTrips() throws {
        let project = Project(
            presets: [
                Preset(
                    id: PresetID(rawValue: "preset-1"),
                    name: "Live",
                    shots: [
                        Shot(
                            id: ShotID(rawValue: "display"), name: "Display",
                            defaultTransition: .wipe(edge: .bottom, duration: 0.4))
                    ]
                )
            ]
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.presets.first?.shots.first?.defaultTransition == .wipe(edge: .bottom, duration: 0.4))
    }

    @Test("a ProjectDestination round-trips through JSON unchanged")
    func destinationRoundTrips() throws {
        let destination = ProjectDestination(url: try #require(URL(string: "rtmps://live.example:443/app")))
        let data = try JSONEncoder().encode(destination)
        let decoded = try JSONDecoder().decode(ProjectDestination.self, from: data)
        #expect(decoded == destination)
    }

    @Test("decoding a ProjectDestination without a url throws a keyNotFound error")
    func destinationMissingURLThrows() throws {
        let json = Data(#"{}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProjectDestination.self, from: json)
        }
    }
}
