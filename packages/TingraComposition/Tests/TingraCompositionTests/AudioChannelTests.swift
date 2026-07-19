//
//  AudioChannelTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-19.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraComposition

/// Verifies the persisted audio-configuration contract: an `AudioChannel`
/// round-trips through JSON exactly, keeps stable keys, decodes forgivingly
/// where fields are optional, and a `Preset`'s optional `audioChannels` key
/// follows the destination rule — absent when unauthored, exact when set
/// (CLAUDE.md, "Data Models"; ARCHITECTURE.md, "Per-strip routing").
@Suite("AudioChannel persistence")
struct AudioChannelTests {
    /// A fully authored channel, no field at its default.
    private let hotChannel = AudioChannel(
        input: InputID(rawValue: "mic-1"),
        name: "Studio Microphone",
        level: 0.8,
        pan: -0.25,
        isMuted: true
    )

    @Test("a channel round-trips through JSON unchanged")
    func channelRoundTrips() throws {
        let data = try JSONEncoder().encode(hotChannel)
        let decoded = try JSONDecoder().decode(AudioChannel.self, from: data)
        #expect(decoded == hotChannel)
    }

    @Test("a channel encodes under the stable camelCase keys")
    func channelKeysAreStable() throws {
        let data = try JSONEncoder().encode(hotChannel)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["input", "name", "level", "pan", "isMuted"])
        #expect(object["input"] as? String == "mic-1")
        #expect(object["name"] as? String == "Studio Microphone")
        #expect(object["level"] as? Double == 0.8)
        #expect(object["pan"] as? Double == -0.25)
        #expect(object["isMuted"] as? Bool == true)
    }

    @Test("decoding a channel without an input throws a keyNotFound error")
    func channelMissingInputThrows() throws {
        let json = Data(#"{"name":"Studio Microphone","level":0.8}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioChannel.self, from: json)
        }
    }

    @Test("a channel with only an input decodes to the strip defaults")
    func channelOptionalFieldsDefault() throws {
        let json = Data(#"{"input":"mic-1"}"#.utf8)
        let decoded = try JSONDecoder().decode(AudioChannel.self, from: json)
        #expect(decoded.name.isEmpty)
        #expect(decoded.level == 1)
        #expect(decoded.pan == 0)
        #expect(decoded.isMuted == false)
    }

    @Test("channels compare equal only when every field matches")
    func channelEquality() {
        let base = AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic", level: 1, pan: 0, isMuted: false)
        let same = AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic", level: 1, pan: 0, isMuted: false)
        #expect(base == same)
        #expect(base != AudioChannel(input: InputID(rawValue: "mic-2"), name: "Mic"))
        #expect(base != AudioChannel(input: InputID(rawValue: "mic-1"), name: "Other"))
        #expect(base != AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic", level: 0.5))
        #expect(base != AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic", pan: 1))
        #expect(base != AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic", isMuted: true))
    }

    // MARK: The preset's audioChannels key

    @Test("a preset's authored channels round-trip through JSON unchanged")
    func presetAudioChannelsRoundTrip() throws {
        let preset = Preset(
            id: PresetID(rawValue: "p"),
            name: "Live",
            audioChannels: [hotChannel, AudioChannel(input: InputID(rawValue: "mic-2"))]
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        #expect(decoded == preset)
        #expect(decoded.audioChannels == preset.audioChannels)
    }

    @Test("a preset with no audioChannels key decodes with no authored audio configuration")
    func presetMissingAudioChannelsDecodesNil() throws {
        let json = Data(#"{"id":"p","name":"Live"}"#.utf8)
        let decoded = try JSONDecoder().decode(Preset.self, from: json)
        #expect(decoded.audioChannels == nil)
    }

    @Test("a preset with no authored audio encodes without the audioChannels key")
    func presetWithoutAudioChannelsOmitsKey() throws {
        let data = try JSONEncoder().encode(Preset(id: PresetID(rawValue: "p"), name: "Live"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "shots"])
    }

    @Test("a preset's authored-empty channel list round-trips as empty, not as unauthored")
    func presetEmptyAudioChannelsRoundTrips() throws {
        let preset = Preset(id: PresetID(rawValue: "p"), name: "Live", audioChannels: [])
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        #expect(decoded.audioChannels == [])
    }

    @Test("presets differing only in authored audio compare not equal")
    func presetAudioChannelsAffectEquality() {
        let id = PresetID(rawValue: "p")
        let base = Preset(id: id, name: "Live", audioChannels: [hotChannel])
        #expect(base == Preset(id: id, name: "Live", audioChannels: [hotChannel]))
        #expect(base != Preset(id: id, name: "Live"))
        #expect(base != Preset(id: id, name: "Live", audioChannels: []))
    }
}
