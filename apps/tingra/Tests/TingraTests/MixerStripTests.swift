//
//  MixerStripTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraComposition
import TingraPlugInKit

@testable import Tingra

@Suite("MixerStrip")
struct MixerStripTests {
    /// A discovered-input choice for seeding.
    @MainActor
    private static func choice(_ id: String) -> EngineModel.InputChoice {
        EngineModel.InputChoice(id: InputID(rawValue: id), name: id)
    }

    @Test("seeding unmutes the first input at unity and mutes the rest")
    @MainActor
    func seedingUnmutesOnlyTheFirstInput() {
        let strips = MixerStrip.seed(from: [Self.choice("mic-1"), Self.choice("mic-2"), Self.choice("mic-3")])

        #expect(strips.count == 3)
        #expect(strips.map(\.isMuted) == [false, true, true])
        #expect(strips.allSatisfy { $0.level == 1 })
        #expect(strips.allSatisfy { $0.pan == 0 })
        #expect(strips.map(\.id.rawValue) == ["mic-1", "mic-2", "mic-3"])
        #expect(strips.map(\.name) == ["mic-1", "mic-2", "mic-3"])
    }

    @Test("seeding from no discovered inputs yields no strips")
    @MainActor
    func seedingFromNoInputsYieldsNoStrips() {
        #expect(MixerStrip.seed(from: []).isEmpty)
    }

    @Test("strips compare equal only when every field matches")
    @MainActor
    func stripEquality() {
        let strip = MixerStrip(id: InputID(rawValue: "mic-1"), name: "Mic", level: 1, pan: 0, isMuted: false)
        var same = strip
        #expect(strip == same)
        same.level = 0.5
        #expect(strip != same)
        same = strip
        same.pan = -1
        #expect(strip != same)
    }

    // MARK: Merging authored channels with discovery

    @Test("merging with no authored channels falls back to the seed policy")
    @MainActor
    func mergingNilChannelsSeeds() {
        let inputs = [Self.choice("mic-1"), Self.choice("mic-2")]
        #expect(MixerStrip.strips(channels: nil, discovered: inputs) == MixerStrip.seed(from: inputs))
    }

    @Test("an authored channel whose device is discovered keeps its settings and takes the discovered name")
    @MainActor
    func mergingAuthoredChannelKeepsSettings() {
        let channel = AudioChannel(
            input: InputID(rawValue: "mic-1"), name: "Old Name", level: 0.6, pan: -0.5, isMuted: true)
        let discovered = EngineModel.InputChoice(id: InputID(rawValue: "mic-1"), name: "Studio Microphone")

        let strips = MixerStrip.strips(channels: [channel], discovered: [discovered])

        #expect(strips.count == 1)
        #expect(strips[0].id.rawValue == "mic-1")
        #expect(strips[0].name == "Studio Microphone")
        #expect(strips[0].level == 0.6)
        #expect(strips[0].pan == -0.5)
        #expect(strips[0].isMuted)
    }

    @Test("an authored channel whose device is absent stays a dormant strip under its cached name")
    @MainActor
    func mergingAbsentDeviceKeepsDormantStrip() {
        let channel = AudioChannel(input: InputID(rawValue: "mic-usb"), name: "USB Microphone", level: 0.4)

        let strips = MixerStrip.strips(channels: [channel], discovered: [])

        #expect(strips.count == 1)
        #expect(strips[0].name == "USB Microphone")
        #expect(strips[0].level == 0.4)
    }

    @Test("an authored channel with no cached name and an absent device falls back to its raw id")
    @MainActor
    func mergingAbsentDeviceWithoutNameShowsRawID() {
        let strips = MixerStrip.strips(channels: [AudioChannel(input: InputID(rawValue: "mic-usb"))], discovered: [])
        #expect(strips.count == 1)
        #expect(strips[0].name == "mic-usb")
    }

    @Test("a discovered device with no authored channel appends muted at unity, centered")
    @MainActor
    func mergingUnauthoredDeviceAppendsMuted() {
        let channel = AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic")
        let inputs = [Self.choice("mic-1"), Self.choice("mic-new")]

        let strips = MixerStrip.strips(channels: [channel], discovered: inputs)

        #expect(strips.count == 2)
        #expect(strips[1].id.rawValue == "mic-new")
        #expect(strips[1].isMuted)
        #expect(strips[1].level == 1)
        #expect(strips[1].pan == 0)
    }

    @Test("merged strips list authored channels first in document order, then new devices in discovery order")
    @MainActor
    func mergingOrdersAuthoredFirst() {
        let channels = [
            AudioChannel(input: InputID(rawValue: "mic-2"), name: "Second"),
            AudioChannel(input: InputID(rawValue: "mic-1"), name: "First"),
        ]
        let inputs = [Self.choice("mic-1"), Self.choice("mic-2"), Self.choice("mic-3")]

        let strips = MixerStrip.strips(channels: channels, discovered: inputs)

        #expect(strips.map(\.id.rawValue) == ["mic-2", "mic-1", "mic-3"])
    }

    @Test("merging an authored-empty channel list yields every discovered device muted")
    @MainActor
    func mergingAuthoredEmptyMutesDiscovery() {
        let strips = MixerStrip.strips(channels: [], discovered: [Self.choice("mic-1"), Self.choice("mic-2")])
        #expect(strips.count == 2)
        #expect(strips.allSatisfy { $0.isMuted })
    }

    @Test("a strip converts to the authored channel the document persists")
    @MainActor
    func stripConvertsToAudioChannel() {
        let strip = MixerStrip(id: InputID(rawValue: "mic-1"), name: "Mic", level: 0.7, pan: 0.5, isMuted: true)
        let channel = strip.audioChannel
        #expect(channel.input.rawValue == "mic-1")
        #expect(channel.name == "Mic")
        #expect(channel.level == 0.7)
        #expect(channel.pan == 0.5)
        #expect(channel.isMuted)
    }
}
