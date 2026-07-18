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

    @Test("projects are equal only when their version, presets, and destination all match")
    func projectEquality() throws {
        let preset = Preset(id: PresetID(rawValue: "p"), name: "Live")
        let destination = ProjectDestination(url: try #require(URL(string: "rtmp://live.example/app")))
        let base = Project(presets: [preset])
        let same = Project(presets: [preset])
        let otherVersion = Project(version: 0, presets: [preset])
        let otherPresets = Project(presets: [])
        let withDestination = Project(presets: [preset], destination: destination)
        #expect(base == same)
        #expect(base != otherVersion)
        #expect(base != otherPresets)
        #expect(base != withDestination)
    }

    // MARK: Destination

    @Test("the document format version is 1 — pre-release, the format grows within v1")
    func currentVersionIsOne() {
        #expect(Project.currentVersion == 1)
    }

    @Test("a project with a destination round-trips through JSON unchanged")
    func projectWithDestinationRoundTrips() throws {
        let project = Project(
            presets: sampleProject.presets,
            destination: ProjectDestination(url: try #require(URL(string: "rtmp://live.twitch.tv/app")))
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.destination?.url.absoluteString == "rtmp://live.twitch.tv/app")
    }

    @Test("a project with a destination encodes version, presets, and destination keys")
    func projectWithDestinationKeys() throws {
        let project = Project(
            presets: sampleProject.presets,
            destination: ProjectDestination(url: try #require(URL(string: "rtmp://live.twitch.tv/app")))
        )
        let data = try JSONEncoder().encode(project)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "presets", "destination"])
    }

    @Test("a document without a destination key decodes with destination nil")
    func missingDestinationDecodesNil() throws {
        let json = Data(#"{"version":1,"presets":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(Project.self, from: json)
        #expect(decoded.version == 1)
        #expect(decoded.destination == nil)
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
