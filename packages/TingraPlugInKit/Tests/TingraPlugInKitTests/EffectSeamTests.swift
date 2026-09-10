//
//  EffectSeamTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import Foundation
import Testing

@testable import TingraPlugInKit

/// Decodes an `EffectConfiguration` from a JSON string.
private func decodeConfiguration(_ json: String) throws -> EffectConfiguration {
    try JSONDecoder().decode(EffectConfiguration.self, from: Data(json.utf8))
}

/// Encodes an `EffectConfiguration` to a JSON string with sorted keys.
private func encodeConfiguration(_ configuration: EffectConfiguration) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(configuration), as: UTF8.self)
}

@Suite("Effect seam")
struct EffectSeamTests {
    @Test("an effect configuration round-trips exactly through JSON")
    func configurationRoundTrip() throws {
        let configuration = EffectConfiguration(
            effect: EffectID(rawValue: "gain"),
            parameters: ["gainDecibels": .double(-6.5), "steps": .int(3)]
        )
        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(EffectConfiguration.self, from: encoded)
        #expect(decoded == configuration)
    }

    @Test("an effect configuration encodes with the stable camelCase keys and a bare-string id")
    func configurationStableKeys() throws {
        let configuration = EffectConfiguration(
            effect: EffectID(rawValue: "highPass"),
            parameters: ["cutoffHertz": .double(80)]
        )
        let json = try encodeConfiguration(configuration)
        #expect(json == #"{"effect":"highPass","parameters":{"cutoffHertz":80}}"#)
    }

    @Test("decoding a configuration without its effect id throws keyNotFound")
    func configurationMissingEffectThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decodeConfiguration(#"{"parameters":{}}"#)
        }
    }

    @Test("a missing parameters key decodes to the empty payload")
    func configurationMissingParametersDefaultsEmpty() throws {
        let decoded = try decodeConfiguration(#"{"effect":"gain"}"#)
        #expect(decoded.effect == EffectID(rawValue: "gain"))
        #expect(decoded.parameters.isEmpty)
    }

    @Test("a configuration naming an effect this build has no provider for still round-trips")
    func configurationUnknownEffectSurvives() throws {
        let decoded = try decodeConfiguration(#"{"effect":"com.example.reverb","parameters":{"mix":0.3}}"#)
        #expect(decoded.effect == EffectID(rawValue: "com.example.reverb"))
        let encoded = try encodeConfiguration(decoded)
        #expect(encoded == #"{"effect":"com.example.reverb","parameters":{"mix":0.3}}"#)
    }

    @Test("configurations compare equal only when id and parameters match")
    func configurationEquality() {
        let gain = EffectConfiguration(effect: EffectID(rawValue: "gain"), parameters: ["gainDecibels": .double(3)])
        let sameGain = EffectConfiguration(
            effect: EffectID(rawValue: "gain"), parameters: ["gainDecibels": .double(3)])
        let otherLevel = EffectConfiguration(
            effect: EffectID(rawValue: "gain"), parameters: ["gainDecibels": .double(6)])
        let otherEffect = EffectConfiguration(
            effect: EffectID(rawValue: "lowPass"), parameters: ["gainDecibels": .double(3)])
        #expect(gain == sameGain)
        #expect(gain != otherLevel)
        #expect(gain != otherEffect)
    }

    @Test("effect parameters compare equal only when every field matches")
    func parameterEquality() {
        let cutoff = EffectParameter(
            key: "cutoffHertz", name: "Cutoff", range: 20...1000, defaultValue: 80, unit: "Hz",
            scale: .logarithmic)
        let same = EffectParameter(
            key: "cutoffHertz", name: "Cutoff", range: 20...1000, defaultValue: 80, unit: "Hz",
            scale: .logarithmic)
        let linear = EffectParameter(
            key: "cutoffHertz", name: "Cutoff", range: 20...1000, defaultValue: 80, unit: "Hz")
        #expect(cutoff == same)
        #expect(cutoff != linear)
    }

    @Test("a numeric parameter is the number kind and a color parameter the color kind")
    func parameterKinds() {
        let number = EffectParameter(key: "radiusPixels", name: "Radius", range: 0...100, defaultValue: 0)
        #expect(number.kind == .number)
        #expect(number.defaultColor == nil)

        let color = EffectParameter(key: "borderColor", name: "Color", defaultColor: .white)
        #expect(color.kind == .color)
        #expect(color.defaultColor == .white)
        #expect(color.key == "borderColor")
        #expect(color.name == "Color")
        #expect(color.unit == nil)
        #expect(color != number)
        #expect(color == EffectParameter(key: "borderColor", name: "Color", defaultColor: .white))
        #expect(color != EffectParameter(key: "borderColor", name: "Color", defaultColor: .black))
    }

    @Test("an effect color round-trips through its payload object and JSON")
    func colorRoundTrip() throws {
        let color = EffectColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)
        #expect(EffectColor(color.jsonValue) == color)
        #expect(
            color.jsonValue
                == .object([
                    "red": .double(0.25), "green": .double(0.5), "blue": .double(0.75), "alpha": .double(0.5),
                ]))

        let data = try JSONEncoder().encode(color)
        #expect(try JSONDecoder().decode(EffectColor.self, from: data) == color)
        let members = try #require(JSONSerialization.jsonObject(with: data) as? [String: Double])
        #expect(members == ["red": 0.25, "green": 0.5, "blue": 0.75, "alpha": 0.5])
    }

    @Test("an effect color read from a payload treats a missing alpha as opaque and rejects other shapes")
    func colorPayloadShapes() {
        let opaque = EffectColor(.object(["red": .int(1), "green": .double(0), "blue": .double(0)]))
        #expect(opaque == EffectColor(red: 1, green: 0, blue: 0))
        #expect(EffectColor(.double(1)) == nil)
        #expect(EffectColor(.string("#ffffff")) == nil)
        #expect(EffectColor(.object(["red": .double(1), "green": .double(1)])) == nil)
    }

    @Test("effect color components are clamped into the unit range on creation")
    func colorClamps() {
        let color = EffectColor(red: 2, green: -1, blue: 0.5, alpha: .nan)
        #expect(color == EffectColor(red: 1, green: 0, blue: 0.5, alpha: 0))
        #expect(EffectColor.white != EffectColor.black)
    }

    @Test("a video effect's output extent defaults to its input extent")
    func outputExtentDefaultsToInput() {
        // A conformer that declares nothing about extents keeps or grows
        // the picture, so a host measuring the layer's picture after the
        // chain sees the input's own extent.
        let extent = CGRect(x: 3, y: 4, width: 640, height: 360)
        #expect(PassthroughVideoEffect().outputExtent(for: extent) == extent)
        #expect(PassthroughVideoEffect().outputExtent(for: .infinite) == .infinite)
    }

    @Test("doubleValue reads a double as-is, widens an integer, and is nil for non-numbers")
    func jsonValueDoubleValue() {
        #expect(JSONValue.double(6.5).doubleValue == 6.5)
        #expect(JSONValue.int(6).doubleValue == 6.0)
        #expect(JSONValue.string("6").doubleValue == nil)
        #expect(JSONValue.bool(true).doubleValue == nil)
        #expect(JSONValue.null.doubleValue == nil)
    }
}

/// A video effect declaring only the seam's two requirements, so the
/// protocol's default extent answer is what gets tested.
private struct PassthroughVideoEffect: VideoEffect {
    /// Ignores every payload.
    func setParameters(_ parameters: [String: JSONValue]) {}

    /// Returns the image unchanged.
    func process(_ image: CIImage) -> CIImage { image }
}
