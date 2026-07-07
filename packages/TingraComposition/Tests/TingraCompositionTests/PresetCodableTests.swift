//
//  PresetCodableTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraComposition

/// Verifies the persisted project contract: `Preset`, `Shot`, and `Layer`
/// round-trip through JSON exactly, keep stable keys, and decode forgivingly
/// where fields are optional (CLAUDE.md, "Data Models").
@Suite("Preset persistence")
struct PresetCodableTests {
    /// A layer with a non-default frame and opacity, for round-trip coverage.
    private let pipLayer = Layer(
        input: InputID(rawValue: "camera-1"),
        frame: CGRect(x: 0.68, y: 0.68, width: 0.28, height: 0.28),
        opacity: 0.9
    )

    /// A preset with two shots, one of them a two-layer picture-in-picture.
    private var samplePreset: Preset {
        Preset(
            id: PresetID(rawValue: "preset-1"),
            name: "Live",
            shots: [
                Shot(
                    id: ShotID(rawValue: "display"), name: "Display",
                    layers: [Layer(input: InputID(rawValue: "display-1"))]),
                Shot(
                    id: ShotID(rawValue: "pip"),
                    name: "Picture in Picture",
                    layers: [Layer(input: InputID(rawValue: "display-1")), pipLayer],
                    background: BackgroundColor(red: 0.1, green: 0.1, blue: 0.1)
                ),
            ]
        )
    }

    @Test("a preset round-trips through JSON unchanged")
    func presetRoundTrips() throws {
        let data = try JSONEncoder().encode(samplePreset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        #expect(decoded == samplePreset)
    }

    @Test("a layer's frame encodes as flat x/y/width/height keys, not nested arrays")
    func layerFrameKeysAreFlat() throws {
        let data = try JSONEncoder().encode(pipLayer)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["x"] as? Double == 0.68)
        #expect(object["y"] as? Double == 0.68)
        #expect(object["width"] as? Double == 0.28)
        #expect(object["height"] as? Double == 0.28)
        #expect(object["opacity"] as? Double == 0.9)
    }

    @Test("decoding a preset without an id throws a keyNotFound error")
    func presetMissingIDThrows() throws {
        let json = Data(#"{"name":"Live"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Preset.self, from: json)
        }
    }

    @Test("decoding a shot without an id throws a keyNotFound error")
    func shotMissingIDThrows() throws {
        let json = Data(#"{"name":"Display"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Shot.self, from: json)
        }
    }

    @Test("decoding a layer without an input throws a keyNotFound error")
    func layerMissingInputThrows() throws {
        let json = Data(#"{"x":0,"y":0,"width":1,"height":1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Layer.self, from: json)
        }
    }

    @Test("a preset with no shots key decodes to an empty shot list")
    func presetOptionalShotsDefaults() throws {
        let json = Data(#"{"id":"p","name":"Empty"}"#.utf8)
        let decoded = try JSONDecoder().decode(Preset.self, from: json)
        #expect(decoded.shots.isEmpty)
    }

    @Test("a shot with no layers or background keys decodes to an empty tree over black")
    func shotOptionalFieldsDefault() throws {
        let json = Data(#"{"id":"s","name":"Bare"}"#.utf8)
        let decoded = try JSONDecoder().decode(Shot.self, from: json)
        #expect(decoded.layers.isEmpty)
        #expect(decoded.background == .black)
    }

    @Test("a layer with only an input decodes to the full-frame, full-opacity defaults")
    func layerOptionalFieldsDefault() throws {
        let json = Data(#"{"input":"camera-1"}"#.utf8)
        let decoded = try JSONDecoder().decode(Layer.self, from: json)
        #expect(decoded.frame == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(decoded.opacity == 1)
    }
}

@Suite("Preset")
struct PresetTests {
    @Test("a preset defaults to no shots and a fresh identity")
    func presetDefaults() {
        let preset = Preset(name: "New")
        #expect(preset.shots.isEmpty)
        #expect(Preset(name: "New").id != Preset(name: "New").id)
    }

    @Test("presets are equal only when their id, name, and shots all match")
    func presetEquality() {
        let id = PresetID(rawValue: "p")
        let shot = Shot(id: ShotID(rawValue: "s"), name: "One")
        let base = Preset(id: id, name: "Live", shots: [shot])
        let same = Preset(id: id, name: "Live", shots: [shot])
        let otherID = Preset(id: PresetID(rawValue: "q"), name: "Live", shots: [shot])
        let otherName = Preset(id: id, name: "Rehearsal", shots: [shot])
        let otherShots = Preset(id: id, name: "Live", shots: [])
        #expect(base == same)
        #expect(base != otherID)
        #expect(base != otherName)
        #expect(base != otherShots)
    }
}
