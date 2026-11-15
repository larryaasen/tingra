//
//  MonitorOverlaySettingsTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraComposition

@Suite("Monitor overlay settings")
struct MonitorOverlaySettingsTests {
    /// Settings with an overlay on each monitor, one only on program, and
    /// stored values for one of them.
    private var sample: MonitorOverlaySettings {
        MonitorOverlaySettings(
            program: [MonitorOverlayID(rawValue: "tallyBorder"), MonitorOverlayID(rawValue: "titleSafe")],
            preview: [MonitorOverlayID(rawValue: "tallyBorder")],
            parameters: ["titleSafe": ["percent": .double(0.88)]]
        )
    }

    @Test("settings round-trip through JSON unchanged, ids as bare strings")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["program", "preview", "parameters"])
        #expect(object["program"] as? [String] == ["tallyBorder", "titleSafe"])
        #expect(try JSONDecoder().decode(MonitorOverlaySettings.self, from: data) == sample)
    }

    @Test("settings with every overlay off still write both monitor lists, and no parameters key")
    func emptyListsAreWritten() throws {
        let data = try JSONEncoder().encode(MonitorOverlaySettings())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["program", "preview"])
        #expect(object["program"] as? [String] == [])
        let decoded = try JSONDecoder().decode(MonitorOverlaySettings.self, from: data)
        #expect(decoded == MonitorOverlaySettings())
    }

    @Test("missing keys decode as empty")
    func missingKeysDecodeEmpty() throws {
        let decoded = try JSONDecoder().decode(MonitorOverlaySettings.self, from: Data("{}".utf8))
        #expect(decoded.program.isEmpty)
        #expect(decoded.preview.isEmpty)
        #expect(decoded.input.isEmpty)
        #expect(decoded.layer.isEmpty)
        #expect(decoded.parameters.isEmpty)
        let onlyPreview = try JSONDecoder().decode(
            MonitorOverlaySettings.self, from: Data(#"{"preview":["centerCross"]}"#.utf8))
        #expect(onlyPreview.preview == [MonitorOverlayID(rawValue: "centerCross")])
        #expect(onlyPreview.program.isEmpty)
    }

    @Test("the input and layer lists round-trip under their own keys, and are left out when empty")
    func inputAndLayerRoundTrip() throws {
        var settings = sample
        settings.input = [MonitorOverlayID(rawValue: "showAlpha")]
        settings.layer = [MonitorOverlayID(rawValue: "flipHorizontal"), MonitorOverlayID(rawValue: "showAlpha")]
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["program", "preview", "input", "layer", "parameters"])
        #expect(object["layer"] as? [String] == ["flipHorizontal", "showAlpha"])
        #expect(try JSONDecoder().decode(MonitorOverlaySettings.self, from: data) == settings)
    }

    @Test("the monitor subscript reads and writes each monitor's own list")
    func monitorSubscript() {
        var settings = MonitorOverlaySettings()
        let ids: [MonitorOverlayContext.Monitor: MonitorOverlayID] = [
            .program: MonitorOverlayID(rawValue: "a"), .preview: MonitorOverlayID(rawValue: "b"),
            .input: MonitorOverlayID(rawValue: "c"), .layer: MonitorOverlayID(rawValue: "d"),
        ]
        for (monitor, id) in ids {
            settings[monitor] = [id]
        }
        #expect(settings.program == [MonitorOverlayID(rawValue: "a")])
        #expect(settings.preview == [MonitorOverlayID(rawValue: "b")])
        #expect(settings.input == [MonitorOverlayID(rawValue: "c")])
        #expect(settings.layer == [MonitorOverlayID(rawValue: "d")])
        for (monitor, id) in ids {
            #expect(settings[monitor] == [id])
        }
    }

    @Test("a list of the wrong shape throws a decoding error")
    func wrongShapeThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MonitorOverlaySettings.self, from: Data(#"{"program":"titleSafe"}"#.utf8))
        }
    }

    @Test("an id no provider knows round-trips untouched")
    func unknownIDRoundTrips() throws {
        let json = Data(#"{"program":["com.example.lowerThirdGuide"],"preview":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(MonitorOverlaySettings.self, from: json)
        let reencoded = try JSONDecoder().decode(
            MonitorOverlaySettings.self, from: try JSONEncoder().encode(decoded))
        #expect(reencoded.program == [MonitorOverlayID(rawValue: "com.example.lowerThirdGuide")])
    }

    @Test("settings are equal only when both lists and the parameters match")
    func equality() {
        #expect(sample == sample)
        var otherProgram = sample
        otherProgram.program.removeLast()
        #expect(otherProgram != sample)
        var otherPreview = sample
        otherPreview.preview = []
        #expect(otherPreview != sample)
        var otherInput = sample
        otherInput.input = [MonitorOverlayID(rawValue: "showAlpha")]
        #expect(otherInput != sample)
        var otherLayer = sample
        otherLayer.layer = [MonitorOverlayID(rawValue: "showAlpha")]
        #expect(otherLayer != sample)
        var otherParameters = sample
        otherParameters.parameters["titleSafe"] = ["percent": .double(0.9)]
        #expect(otherParameters != sample)
    }

    @Test("a document without a monitorOverlays key decodes with monitorOverlays nil")
    func projectWithoutKey() throws {
        let decoded = try JSONDecoder().decode(Project.self, from: Data(#"{"version":1,"presets":[]}"#.utf8))
        #expect(decoded.monitorOverlays == nil)
        let object = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(object["monitorOverlays"] == nil)
    }

    @Test("a project with monitor overlays round-trips through JSON under a monitorOverlays key")
    func projectRoundTrip() throws {
        let project = Project(monitorOverlays: sample)
        let data = try JSONEncoder().encode(project)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "presets", "monitorOverlays"])
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.monitorOverlays == sample)
    }

    @Test("projects are equal only when their monitor overlays match")
    func projectEquality() {
        #expect(Project(monitorOverlays: sample) == Project(monitorOverlays: sample))
        #expect(Project(monitorOverlays: sample) != Project(monitorOverlays: MonitorOverlaySettings()))
        #expect(Project(monitorOverlays: sample) != Project())
    }
}
