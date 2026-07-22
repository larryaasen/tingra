//
//  EffectSeamTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

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

    @Test("doubleValue reads a double as-is, widens an integer, and is nil for non-numbers")
    func jsonValueDoubleValue() {
        #expect(JSONValue.double(6.5).doubleValue == 6.5)
        #expect(JSONValue.int(6).doubleValue == 6.0)
        #expect(JSONValue.string("6").doubleValue == nil)
        #expect(JSONValue.bool(true).doubleValue == nil)
        #expect(JSONValue.null.doubleValue == nil)
    }
}
