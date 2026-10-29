//
//  CameraPresetsTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraHost

/// The camera preset rules: saving, renaming, updating, the default and what
/// deleting does to it, the suggested name, finding a preset's camera, and
/// the JSON contract.
@Suite("CameraPresets")
struct CameraPresetsTests {
    /// A camera's control values.
    static let values: [String: JSONValue] = ["brightness": 95, "autoWhiteBalance": false, "zoom": 150]

    /// A list with one preset saved from the Razer.
    static func oneSaved() throws -> (CameraPresets, CameraPreset) {
        var presets = CameraPresets()
        let preset = try save(
            "Desk", into: &presets, cameraID: "0x211100015320e05", cameraName: "Razer Kiyo Pro", values: values)
        return (presets, preset)
    }

    /// Saves a preset into a list, requiring that it was saved.
    static func save(
        _ name: String,
        into presets: inout CameraPresets,
        cameraID: String = "a",
        cameraName: String = "A",
        values: [String: JSONValue] = [:]
    ) throws -> CameraPreset {
        let saved = presets.save(name: name, cameraID: cameraID, cameraName: cameraName, values: values)
        return try #require(saved)
    }

    // MARK: Saving and the default

    @Test("a new list holds no preset and has no default")
    func startsEmpty() {
        let presets = CameraPresets()
        #expect(presets.isEmpty)
        #expect(presets.defaultPresetID == nil)
        #expect(presets.defaultPreset == nil)
    }

    @Test("the first preset saved becomes the default")
    func firstSavedIsDefault() throws {
        let (presets, preset) = try Self.oneSaved()
        #expect(presets.presets == [preset])
        #expect(presets.defaultPreset == preset)
        #expect(presets.isDefault(preset.id))
        #expect(preset.name == "Desk")
        #expect(preset.cameraID == "0x211100015320e05")
        #expect(preset.cameraName == "Razer Kiyo Pro")
        #expect(preset.values == Self.values)
    }

    @Test("a later preset is added at the end and leaves the default alone")
    func laterSavedKeepsDefault() throws {
        var (presets, first) = try Self.oneSaved()
        let second = try Self.save("Wide", into: &presets)
        #expect(presets.presets.map(\.id) == [first.id, second.id])
        #expect(presets.defaultPresetID == first.id)
        #expect(!presets.isDefault(second.id))
    }

    @Test("a saved name is trimmed, and an empty one saves nothing")
    func saveTrimsName() {
        var presets = CameraPresets()
        let blank = presets.save(name: "  \n", cameraID: "a", cameraName: "A", values: [:])
        #expect(blank == nil)
        #expect(presets.isEmpty)
        #expect(presets.defaultPresetID == nil)
        let trimmed = presets.save(name: "  Close Up \n", cameraID: "a", cameraName: "A", values: [:])
        #expect(trimmed?.name == "Close Up")
    }

    @Test("any preset can be made the default")
    func makeDefault() throws {
        var (presets, first) = try Self.oneSaved()
        let second = try Self.save("Wide", into: &presets)
        let result1 = presets.makeDefault(second.id)
        #expect(result1)
        #expect(presets.defaultPreset == second)
        let result2 = presets.makeDefault(second.id)
        #expect(!result2, "already the default")
        let result3 = presets.makeDefault(UUID())
        #expect(!result3, "no such preset")
        #expect(presets.defaultPresetID == second.id)
        #expect(!presets.isDefault(first.id))
    }

    // MARK: Deleting

    @Test("deleting a preset that is not the default keeps the default")
    func deleteOther() throws {
        var (presets, first) = try Self.oneSaved()
        let second = try Self.save("Wide", into: &presets)
        let result4 = presets.delete(second.id)
        #expect(result4 == second)
        #expect(presets.presets == [first])
        #expect(presets.defaultPresetID == first.id)
    }

    @Test("deleting the default makes the first preset left the default")
    func deleteDefault() throws {
        var (presets, first) = try Self.oneSaved()
        let second = try Self.save("Wide", into: &presets)
        let third = try Self.save("Close", into: &presets)
        presets.makeDefault(third.id)
        presets.delete(third.id)
        #expect(presets.defaultPresetID == first.id)
        presets.delete(first.id)
        #expect(presets.defaultPresetID == second.id)
    }

    @Test("deleting the last preset leaves no default")
    func deleteLast() throws {
        var (presets, preset) = try Self.oneSaved()
        presets.delete(preset.id)
        #expect(presets.isEmpty)
        #expect(presets.defaultPresetID == nil)
    }

    @Test("deleting a preset that is not in the list returns nil and changes nothing")
    func deleteMissing() throws {
        var (presets, _) = try Self.oneSaved()
        let before = presets
        let result5 = presets.delete(UUID())
        #expect(result5 == nil)
        #expect(presets == before)
    }

    // MARK: Renaming and updating

    @Test("renaming trims the name and keeps the preset's identity, camera, and values")
    func rename() throws {
        var (presets, preset) = try Self.oneSaved()
        let result6 = presets.rename(preset.id, to: "  Studio ")
        #expect(result6)
        let renamed = try #require(presets.preset(withID: preset.id))
        #expect(renamed.name == "Studio")
        #expect(renamed.cameraID == preset.cameraID)
        #expect(renamed.values == preset.values)
    }

    @Test("renaming to an empty name, the same name, or a missing preset changes nothing")
    func renameNoChange() throws {
        var (presets, preset) = try Self.oneSaved()
        let before = presets
        let result7 = presets.rename(preset.id, to: " ")
        #expect(!result7)
        let result8 = presets.rename(preset.id, to: "Desk")
        #expect(!result8)
        let result9 = presets.rename(UUID(), to: "Other")
        #expect(!result9)
        #expect(presets == before)
    }

    @Test("updating replaces the values and keeps the name and place")
    func update() throws {
        var (presets, preset) = try Self.oneSaved()
        presets.save(name: "Wide", cameraID: "a", cameraName: "A", values: [:])
        let fresh: [String: JSONValue] = ["brightness": 40]
        let result10 = presets.update(preset.id, values: fresh)
        #expect(result10)
        #expect(presets.presets.first?.values == fresh)
        #expect(presets.presets.first?.name == "Desk")
        let result11 = presets.update(preset.id, values: fresh)
        #expect(!result11, "the same values")
        let result12 = presets.update(UUID(), values: fresh)
        #expect(!result12, "no such preset")
    }

    // MARK: The suggested name

    @Test("the suggested name numbers past the presets saved")
    func suggestedName() throws {
        var presets = CameraPresets()
        let name: (Int) -> String = { "Preset \($0)" }
        #expect(presets.suggestedName(name) == "Preset 1")
        presets.save(name: "Desk", cameraID: "a", cameraName: "A", values: [:])
        #expect(presets.suggestedName(name) == "Preset 2")
    }

    @Test("the suggested name skips a number already taken")
    func suggestedNameSkipsTaken() {
        var presets = CameraPresets()
        presets.save(name: "Preset 2", cameraID: "a", cameraName: "A", values: [:])
        presets.save(name: "Preset 3", cameraID: "a", cameraName: "A", values: [:])
        #expect(presets.suggestedName { "Preset \($0)" } == "Preset 4")
    }

    // MARK: Finding the preset's camera

    /// A connected camera, as a front end lists it.
    struct Camera: Equatable {
        /// Its identifier.
        let id: String
        /// Its name.
        let name: String
    }

    /// Finds a preset's camera among some cameras.
    static func camera(for preset: CameraPreset, among cameras: [Camera]) -> Camera? {
        preset.camera(among: cameras, id: \.id, name: \.name)
    }

    @Test("a preset finds its camera by id first")
    func cameraByID() throws {
        let (_, preset) = try Self.oneSaved()
        let razer = Camera(id: "0x211100015320e05", name: "Razer Kiyo Pro")
        let renamed = Camera(id: "other", name: "Razer Kiyo Pro")
        #expect(Self.camera(for: preset, among: [renamed, razer]) == razer)
    }

    @Test("a preset finds its camera by name when the id changed, as on another USB port")
    func cameraByName() throws {
        let (_, preset) = try Self.oneSaved()
        let moved = Camera(id: "0x14100015320e05", name: "Razer Kiyo Pro")
        let facetime = Camera(id: "facetime", name: "FaceTime HD Camera")
        #expect(Self.camera(for: preset, among: [facetime, moved]) == moved)
    }

    @Test("a preset whose camera is not connected finds none")
    func cameraMissing() throws {
        let (_, preset) = try Self.oneSaved()
        #expect(Self.camera(for: preset, among: [Camera(id: "facetime", name: "FaceTime HD Camera")]) == nil)
        #expect(Self.camera(for: preset, among: []) == nil)
    }

    // MARK: The JSON contract

    @Test("a preset list round-trips through JSON unchanged")
    func roundTrips() throws {
        var (presets, _) = try Self.oneSaved()
        let second = try Self.save("Wide", into: &presets)
        presets.makeDefault(second.id)
        let decoded = try JSONDecoder().decode(CameraPresets.self, from: JSONEncoder().encode(presets))
        #expect(decoded == presets)
    }

    @Test("the JSON keys are the contract")
    func jsonKeys() throws {
        let (presets, _) = try Self.oneSaved()
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(presets)) as? [String: Any])
        #expect(Set(object.keys) == ["presets", "defaultPresetID"])
        let preset = try #require((object["presets"] as? [[String: Any]])?.first)
        #expect(Set(preset.keys) == ["id", "name", "cameraID", "cameraName", "values"])
    }

    @Test("a list with no defaultPresetID key reads with its first preset as the default")
    func missingDefaultKey() throws {
        let id = UUID()
        let json = """
            {"presets": [{"id": "\(id.uuidString)", "name": "Desk", "cameraID": "a", "cameraName": "A", "values": {}}]}
            """
        let presets = try JSONDecoder().decode(CameraPresets.self, from: Data(json.utf8))
        #expect(presets.defaultPresetID == id)
    }

    @Test("a default naming no preset reads as the first preset")
    func strayDefault() throws {
        let id = UUID()
        let json = """
            {"defaultPresetID": "\(UUID().uuidString)",
             "presets": [{"id": "\(id.uuidString)", "name": "Desk", "cameraID": "a", "cameraName": "A", "values": {}}]}
            """
        #expect(try JSONDecoder().decode(CameraPresets.self, from: Data(json.utf8)).defaultPresetID == id)
    }

    @Test("decoding throws keyNotFound for the missing presets key")
    func missingPresetsKey() {
        #expect {
            try JSONDecoder().decode(CameraPresets.self, from: Data("{}".utf8))
        } throws: { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return false }
            return key.stringValue == "presets"
        }
    }

    @Test(
        "decoding a preset throws keyNotFound for each missing required key",
        arguments: [
            "id", "name", "cameraID", "cameraName", "values",
        ])
    func presetMissingKey(_ missing: String) throws {
        var object: [String: Any] = [
            "id": UUID().uuidString, "name": "Desk", "cameraID": "a", "cameraName": "A", "values": [String: Any](),
        ]
        object[missing] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect {
            try JSONDecoder().decode(CameraPreset.self, from: data)
        } throws: { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return false }
            return key.stringValue == missing
        }
    }

    @Test("presets with the same fields are equal, and differ when a field differs")
    func equality() {
        let id = UUID()
        let preset = CameraPreset(id: id, name: "Desk", cameraID: "a", cameraName: "A", values: Self.values)
        #expect(preset == CameraPreset(id: id, name: "Desk", cameraID: "a", cameraName: "A", values: Self.values))
        #expect(preset != CameraPreset(id: id, name: "Wide", cameraID: "a", cameraName: "A", values: Self.values))
        #expect(preset != CameraPreset(id: id, name: "Desk", cameraID: "a", cameraName: "A", values: [:]))
        #expect(preset != CameraPreset(name: "Desk", cameraID: "a", cameraName: "A", values: Self.values))
    }
}
