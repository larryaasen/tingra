//
//  MixerStripTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

@Suite("MixerStrip")
struct MixerStripTests {
    /// A discovered-input choice for seeding. Defaults to a captured input;
    /// pass `.generator` for a synthesized one.
    @MainActor
    private static func choice(_ id: String, kind: InputKind = .microphone) -> EngineModel.InputChoice {
        EngineModel.InputChoice(id: InputID(rawValue: id), name: id, kind: kind)
    }

    @Test("seeding makes one strip, the first input, unmuted at unity and centered")
    @MainActor
    func seedingMakesOneStripOnTheFirstInput() {
        let strips = MixerStrip.seed(from: [Self.choice("mic-1"), Self.choice("mic-2"), Self.choice("mic-3")])

        // The other microphones are not strips at all: they stay in the
        // sidebar for the operator to add.
        #expect(strips == [MixerStrip(id: InputID(rawValue: "mic-1"), name: "mic-1", level: 1, pan: 0, isMuted: false)])
    }

    @Test("seeding prefers the system default microphone over the first by name")
    @MainActor
    func seedingPrefersTheSystemDefault() {
        let strips = MixerStrip.seed(
            from: [Self.choice("Built-in"), Self.choice("Wireless"), Self.choice("Webcam")],
            preferring: InputID(rawValue: "Wireless")
        )

        #expect(strips.map(\.id.rawValue) == ["Wireless"])
        #expect(strips.first?.isMuted == false)
    }

    @Test("seeding falls back to the first microphone when the default is not discovered")
    @MainActor
    func seedingFallsBackWhenTheDefaultIsAbsent() {
        let strips = MixerStrip.seed(
            from: [Self.choice("mic-1"), Self.choice("mic-2")], preferring: InputID(rawValue: "gone"))

        #expect(strips.map(\.id.rawValue) == ["mic-1"])
    }

    @Test("seeding never seeds a generator, even when it is passed as the default")
    @MainActor
    func seedingIgnoresAGeneratorDefault() {
        let strips = MixerStrip.seed(
            from: [Self.choice("440 Hz Tone", kind: .generator), Self.choice("mic-1")],
            preferring: InputID(rawValue: "440 Hz Tone")
        )

        #expect(strips.map(\.id.rawValue) == ["mic-1"])
    }

    @Test("seeding from no discovered inputs yields no strips")
    @MainActor
    func seedingFromNoInputsYieldsNoStrips() {
        #expect(MixerStrip.seed(from: []).isEmpty)
    }

    @Test("seeding never unmutes a generator, even when it sorts first")
    @MainActor
    func seedingSkipsGeneratorsSortingFirst() {
        // The 440 Hz tone genuinely sorts ahead of every microphone by name,
        // so this is the real discovery order once audio generators became
        // channel strips. Unmuting also starts the input, so seeding the
        // tone would put it on the program mix of a fresh project.
        let strips = MixerStrip.seed(from: [
            Self.choice("440 Hz Tone", kind: .generator),
            Self.choice("MacBook Pro Microphone"),
        ])

        #expect(strips.map(\.id.rawValue) == ["MacBook Pro Microphone"])
        #expect(strips.map(\.isMuted) == [false])
    }

    @Test("seeding never unmutes a media file's sound, even when it sorts first")
    @MainActor
    func seedingSkipsMediaSortingFirst() {
        // A movie's audio strip is authored content the operator added, not
        // what they asked to hear by launching the app; the microphone is.
        let strips = MixerStrip.seed(from: [
            Self.choice("Ad.mov", kind: .media),
            Self.choice("MacBook Pro Microphone"),
        ])

        #expect(strips.map(\.id.rawValue) == ["MacBook Pro Microphone"])
    }

    @Test("seeding with only generators and media yields an empty mixer")
    @MainActor
    func seedingWithOnlyGeneratorsIsEmpty() {
        let strips = MixerStrip.seed(from: [
            Self.choice("440 Hz Tone", kind: .generator),
            Self.choice("Ad.mov", kind: .media),
        ])

        // An empty mixer the operator can add to, never an unrequested tone.
        #expect(strips.isEmpty)
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
        let preferred = InputID(rawValue: "mic-2")
        #expect(
            MixerStrip.strips(channels: nil, discovered: inputs, preferring: preferred)
                == MixerStrip.seed(from: inputs, preferring: preferred))
    }

    @Test("an authored channel whose device is discovered keeps its settings and takes the discovered name")
    @MainActor
    func mergingAuthoredChannelKeepsSettings() {
        let channel = AudioChannel(
            input: InputID(rawValue: "mic-1"), name: "Old Name", level: 0.6, pan: -0.5, isMuted: true)
        let discovered = EngineModel.InputChoice(
            id: InputID(rawValue: "mic-1"), name: "Studio Microphone", kind: .microphone)

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

    @Test("a discovered device with no authored channel gets no strip")
    @MainActor
    func mergingLeavesUnauthoredDevicesOff() {
        let channel = AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic")
        let inputs = [Self.choice("mic-1"), Self.choice("mic-new"), Self.choice("440 Hz Tone", kind: .generator)]

        let strips = MixerStrip.strips(channels: [channel], discovered: inputs)

        // The mixer holds what the show uses; connected is not used.
        #expect(strips.map(\.id.rawValue) == ["mic-1"])
    }

    @Test("strips list the authored channels in document order, not discovery order")
    @MainActor
    func mergingKeepsDocumentOrder() {
        let channels = [
            AudioChannel(input: InputID(rawValue: "mic-2"), name: "Second"),
            AudioChannel(input: InputID(rawValue: "mic-1"), name: "First"),
        ]
        let inputs = [Self.choice("mic-1"), Self.choice("mic-2"), Self.choice("mic-3")]

        let strips = MixerStrip.strips(channels: channels, discovered: inputs)

        #expect(strips.map(\.id.rawValue) == ["mic-2", "mic-1"])
    }

    @Test("an authored channel naming a private aggregate device is dropped rather than kept as a dormant strip")
    @MainActor
    func mergingDropsPrivateAggregateChannels() {
        // What a launch that started the monitor authored before the capture
        // plug-in declined these: the process's own aggregate, muted, named
        // after its pid, its device gone with that launch.
        let channels = [
            AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic", level: 0.8),
            AudioChannel(
                input: InputID(rawValue: "CADefaultDeviceAggregate-52523-0"),
                name: "CADefaultDeviceAggregate-52523-0", isMuted: true),
            AudioChannel(input: InputID(rawValue: "mic-2"), name: "Second Mic"),
        ]

        let strips = MixerStrip.strips(channels: channels, discovered: [Self.choice("mic-1")])

        #expect(strips.map(\.id.rawValue) == ["mic-1", "mic-2"])
        #expect(strips[0].level == 0.8)
        // The absent second microphone stays a dormant strip, authored as it
        // was; only the aggregate is gone.
        #expect(strips[1].audioChannel == channels[2])
    }

    @Test("dropping every authored channel leaves an empty mixer, not the seed policy")
    @MainActor
    func droppingAllChannelsIsNotSeeding() {
        let channels = [
            AudioChannel(input: InputID(rawValue: "CADefaultDeviceAggregate-1-0"), isMuted: true),
            AudioChannel(input: InputID(rawValue: "CADefaultDeviceAggregate-2-0"), isMuted: true),
        ]

        let strips = MixerStrip.strips(channels: channels, discovered: [Self.choice("mic-1"), Self.choice("mic-2")])

        // The document authored audio, so nothing is seeded on its behalf.
        #expect(strips.isEmpty)
    }

    @Test("an authored-empty channel list is an empty mixer")
    @MainActor
    func mergingAuthoredEmptyIsAnEmptyMixer() {
        let strips = MixerStrip.strips(
            channels: [], discovered: [Self.choice("mic-1"), Self.choice("mic-2")],
            preferring: InputID(rawValue: "mic-1"))
        #expect(strips.isEmpty)
    }

    @Test("a device connected mid-session gets no strip, even when it sorts first by name")
    @MainActor
    func hotPluggedDeviceIsNeverSurpriseLive() {
        // The hot-plug failure this guards: the audio list is name-sorted, so
        // a newly connected device can arrive at the *front* of discovery.
        // Were the refresh to fall through to `seed(from:)`, that device
        // would be unmuted — and unmuting also starts it — putting an
        // unasked-for microphone on the program mix and on any live stream.
        // Every refresh goes through the authored path for exactly this
        // reason (ARCHITECTURE.md, "Live device lists in the app").
        let authored = AudioChannel(input: InputID(rawValue: "vocaster"), name: "Vocaster One USB", isMuted: false)
        let discovered = [Self.choice("arrival", kind: .microphone), Self.choice("vocaster")]

        let strips = MixerStrip.strips(channels: [authored], discovered: discovered)

        // Since 2026-11-07 the arrival appears in the sidebar and nowhere
        // else, which is stronger than arriving muted.
        #expect(strips.contains { $0.id.rawValue == "arrival" } == false)
        // ...and the strip that was already live stays live.
        #expect(strips.first { $0.id.rawValue == "vocaster" }?.isMuted == false)
    }

    // MARK: A device under a new id

    /// A discovered input with a distinct id and name, the way a USB device's
    /// uniqueID carries its port and its name does not.
    @MainActor
    private static func device(_ id: String, _ name: String) -> EngineModel.InputChoice {
        EngineModel.InputChoice(id: InputID(rawValue: id), name: name, kind: .microphone)
    }

    @Test("a channel whose device moved to another USB port finds it by name and keeps its settings")
    @MainActor
    func channelFollowsItsDeviceToANewPort() {
        // Larry's soundbar, authored on one port and connected on another.
        let channel = AudioChannel(
            input: InputID(rawValue: "AppleUSBAudioEngine:Dell:Dell AC511 USB SoundBar:2113000:2,1"),
            name: "Dell AC511 USB SoundBar", level: 0.5, pan: 0.25, isMuted: false)
        let current = Self.device(
            "AppleUSBAudioEngine:Dell:Dell AC511 USB SoundBar:113000:2,1", "Dell AC511 USB SoundBar")

        let strips = MixerStrip.strips(channels: [channel], discovered: [current, Self.device("mic", "Built-in")])

        #expect(strips.count == 1)
        #expect(strips[0].id == current.id)
        #expect(strips[0].level == 0.5)
        #expect(strips[0].pan == 0.25)
        #expect(strips[0].isMuted == false)
        // The next sync writes the device's current id into the document.
        #expect(strips[0].audioChannel.input == current.id)
    }

    @Test("a device already on the mixer under its own id is not taken by a stale channel of the same name")
    @MainActor
    func staleChannelDoesNotTakeAClaimedDevice() {
        // The two Razer strips: one per port the camera was ever plugged into.
        let channels = [
            AudioChannel(input: InputID(rawValue: "razer:111000"), name: "Razer Kiyo Pro", level: 0.3),
            AudioChannel(input: InputID(rawValue: "razer:2111000"), name: "Razer Kiyo Pro", level: 0.9),
        ]

        let strips = MixerStrip.strips(channels: channels, discovered: [Self.device("razer:2111000", "Razer Kiyo Pro")])

        // A device is never two strips: the exact match keeps it, and the
        // stale channel stays dormant for the operator to remove.
        #expect(strips.map(\.id.rawValue) == ["razer:111000", "razer:2111000"])
        #expect(strips[1].level == 0.9)
    }

    @Test("two stale channels of one name: the first in document order takes the device")
    @MainActor
    func firstStaleChannelTakesTheDevice() {
        let channels = [
            AudioChannel(input: InputID(rawValue: "old-a"), name: "Soundbar", level: 0.2),
            AudioChannel(input: InputID(rawValue: "old-b"), name: "Soundbar", level: 0.8),
        ]

        let strips = MixerStrip.strips(channels: channels, discovered: [Self.device("new", "Soundbar")])

        #expect(strips.map(\.id.rawValue) == ["new", "old-b"])
        #expect(strips[0].level == 0.2)
    }

    @Test("a name shared by two discovered devices is not guessed")
    @MainActor
    func ambiguousNameStaysDormant() {
        let channel = AudioChannel(input: InputID(rawValue: "old"), name: "USB Audio")

        let strips = MixerStrip.strips(
            channels: [channel], discovered: [Self.device("a", "USB Audio"), Self.device("b", "USB Audio")])

        #expect(strips.map(\.id.rawValue) == ["old"])
    }

    @Test("a channel with no cached name is never matched by name")
    @MainActor
    func namelessChannelStaysDormant() {
        let strips = MixerStrip.strips(
            channels: [AudioChannel(input: InputID(rawValue: "old"))], discovered: [Self.device("new", "")])

        #expect(strips.map(\.id.rawValue) == ["old"])
    }

    @Test("a strip whose device disconnects mid-session stays on the panel with its settings")
    @MainActor
    func disconnectedDeviceKeepsItsStrip() {
        // The other half of hot-plug: the device leaves discovery, but its
        // authored channel does not leave the preset, so the strip stays —
        // dormant under its cached name, settings intact for the device's
        // return. The layer-bound-to-an-undiscovered-input semantic.
        let authored = AudioChannel(
            input: InputID(rawValue: "vocaster"), name: "Vocaster One USB",
            level: 0.6, pan: -0.25, isMuted: false)

        let strips = MixerStrip.strips(channels: [authored], discovered: [])

        #expect(strips.count == 1)
        #expect(strips[0].name == "Vocaster One USB")
        #expect(strips[0].level == 0.6)
        #expect(strips[0].pan == -0.25)
        #expect(strips[0].isMuted == false)
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

    @Test("a chainless strip authors no effects key, so a document that never used effects is unchanged")
    @MainActor
    func chainlessStripAuthorsNoEffectsKey() {
        let strip = MixerStrip(id: InputID(rawValue: "mic-1"), name: "Mic", level: 1, pan: 0, isMuted: false)
        #expect(strip.effects.isEmpty)
        #expect(strip.audioChannel.effects == nil)
    }

    @Test("a strip's effect chain converts to the authored channel in signal order")
    @MainActor
    func stripChainConvertsInSignalOrder() {
        let chain = [
            EffectConfiguration(effect: EffectID(rawValue: "highPass"), parameters: ["cutoffHertz": .double(80)]),
            EffectConfiguration(effect: EffectID(rawValue: "gain"), parameters: ["gainDecibels": .double(-3)]),
        ]
        let strip = MixerStrip(
            id: InputID(rawValue: "mic-1"), name: "Mic", level: 1, pan: 0, isMuted: false, effects: chain)
        #expect(strip.audioChannel.effects == chain)
        #expect(strip.audioChannel.effects?.map(\.effect.rawValue) == ["highPass", "gain"])
    }

    @Test("merging adopts an authored channel's effect chain, and a channel without one merges chainless")
    @MainActor
    func mergingAdoptsAuthoredChain() {
        let chain = [EffectConfiguration(effect: EffectID(rawValue: "gain"), parameters: ["gainDecibels": .double(6)])]
        let channels = [
            AudioChannel(input: InputID(rawValue: "mic-1"), name: "Mic 1", effects: chain),
            AudioChannel(input: InputID(rawValue: "mic-2"), name: "Mic 2"),
        ]
        let strips = MixerStrip.strips(
            channels: channels, discovered: [Self.choice("mic-1"), Self.choice("mic-2")])

        #expect(strips.count == 2)
        #expect(strips[0].effects == chain)
        #expect(strips[1].effects.isEmpty)
    }

    // MARK: Adding strips

    @Test("an added strip is muted at unity, centered, and chainless, under the input's name")
    @MainActor
    func addedStripIsMuted() {
        let strip = MixerStrip.added(Self.choice("Wireless MICRO"))

        #expect(strip.id.rawValue == "Wireless MICRO")
        #expect(strip.name == "Wireless MICRO")
        #expect(strip.isMuted)
        #expect(strip.level == 1)
        #expect(strip.pan == 0)
        #expect(strip.effects.isEmpty)
    }

    @Test("placing a media file with sound in a shot adds its strip, muted")
    @MainActor
    func placingMediaWithSoundAddsAStrip() {
        let strip = MixerStrip.mediaStrip(
            for: InputID(rawValue: "Ad.mov"), strips: [], discovered: [Self.choice("Ad.mov", kind: .media)])

        #expect(strip == MixerStrip.added(Self.choice("Ad.mov", kind: .media)))
    }

    @Test("placing a media file already on the mixer adds nothing")
    @MainActor
    func placingMediaAlreadyOnTheMixerAddsNothing() {
        let existing = MixerStrip(id: InputID(rawValue: "Ad.mov"), name: "Ad.mov", level: 0.5, pan: 0, isMuted: false)

        let strip = MixerStrip.mediaStrip(
            for: InputID(rawValue: "Ad.mov"), strips: [existing], discovered: [Self.choice("Ad.mov", kind: .media)])

        #expect(strip == nil)
    }

    @Test("placing a media file without sound adds nothing")
    @MainActor
    func placingSilentMediaAddsNothing() {
        // A file without an audio track is not in the audio list at all.
        let strip = MixerStrip.mediaStrip(for: InputID(rawValue: "Still.png"), strips: [], discovered: [])

        #expect(strip == nil)
    }

    @Test("placing a microphone or a generator in a shot never adds a strip")
    @MainActor
    func placingNonMediaAddsNothing() {
        let discovered = [Self.choice("mic-1"), Self.choice("440 Hz Tone", kind: .generator)]

        #expect(MixerStrip.mediaStrip(for: InputID(rawValue: "mic-1"), strips: [], discovered: discovered) == nil)
        #expect(MixerStrip.mediaStrip(for: InputID(rawValue: "440 Hz Tone"), strips: [], discovered: discovered) == nil)
    }

    @Test("strips differing only in their effect chain compare not equal")
    @MainActor
    func stripChainAffectsEquality() {
        let plain = MixerStrip(id: InputID(rawValue: "mic-1"), name: "Mic", level: 1, pan: 0, isMuted: false)
        let chained = MixerStrip(
            id: InputID(rawValue: "mic-1"), name: "Mic", level: 1, pan: 0, isMuted: false,
            effects: [EffectConfiguration(effect: EffectID(rawValue: "gain"))])
        #expect(plain != chained)
    }
}

/// The model's mixer membership surface, on a model that has not booted: no
/// input is discovered, so nothing can be added, and every query answers for
/// an empty mixer.
@Suite("EngineModel mixer membership")
@MainActor
struct MixerMembershipModelTests {
    /// A model over throwaway preferences and a silent monitor, so the test
    /// touches no device and none of the developer's settings.
    private func makeModel(suiteName: String) throws -> EngineModel {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return EngineModel(
            monitor: SilentMonitor(), snapshotPreferences: SnapshotPreferences(defaults: defaults),
            recordingPreferences: RecordingPreferences(defaults: defaults), defaultMicrophoneID: { nil })
    }

    @Test("an input discovery does not hold cannot be added")
    func undiscoveredInputIsNotAdded() async throws {
        let suiteName = "MixerMembershipModelTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        let id = InputID(rawValue: "mic-1")

        #expect(model.addStrip(for: id) == false)
        #expect(model.mixerStrips.isEmpty)
        #expect(model.isOnMixer(id) == false)
        #expect(model.isLiveInMix(id) == false)
    }

    @Test("removing a strip that is not on the mixer changes nothing")
    func removingAnAbsentStripIsHarmless() async throws {
        let suiteName = "MixerMembershipModelTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)

        await model.removeStrip(InputID(rawValue: "mic-1"))

        #expect(model.mixerStrips.isEmpty)
        #expect(model.audioInputsOffMixer.isEmpty)
    }
}
