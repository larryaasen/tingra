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

    @Test("projects are equal only when their version and presets both match")
    func projectEquality() {
        let preset = Preset(id: PresetID(rawValue: "p"), name: "Live")
        let base = Project(presets: [preset])
        let same = Project(presets: [preset])
        let otherVersion = Project(version: 0, presets: [preset])
        let otherPresets = Project(presets: [])
        #expect(base == same)
        #expect(base != otherVersion)
        #expect(base != otherPresets)
    }
}
