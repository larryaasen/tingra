//
//  MediaChoiceTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import Tingra

/// A hardware-free stand-in for a discovered input, per the project's
/// generators-and-mocks testing rule.
private struct MockInput: Input {
    let id: InputID
    let name: String
    let kind: InputKind
    let media: InputMedia

    func start() async throws {}
    func stop() async {}
}

/// A camera, a display, a microphone, two video generators and one audio
/// generator — the mix the app's discovery actually sees once the
/// first-party plug-ins are activated. Deliberately not in name order, so
/// the sort is doing real work.
private let discovered: [any Input] = [
    MockInput(id: InputID(rawValue: "tone"), name: "440 Hz Tone", kind: .generator, media: .audio),
    MockInput(id: InputID(rawValue: "cam"), name: "FaceTime HD Camera", kind: .camera, media: .video),
    MockInput(id: InputID(rawValue: "bars"), name: "SMPTE Bars", kind: .generator, media: .video),
    MockInput(id: InputID(rawValue: "mic"), name: "MacBook Pro Microphone", kind: .microphone, media: .audio),
    MockInput(id: InputID(rawValue: "display"), name: "Built-in Display", kind: .display, media: .video),
    MockInput(id: InputID(rawValue: "quiet"), name: "Declares Nothing", kind: .generator, media: []),
]

@Suite("Media-role input choices")
struct MediaChoiceTests {
    @Test("the video role includes cameras, displays, and video generators")
    func videoRoleIncludesGenerators() {
        let choices = EngineModel.mediaChoices(from: discovered, producing: .video)

        // The point of the capability: a video generator is a legal layer,
        // and its kind could never have said so.
        #expect(choices.map(\.id.rawValue) == ["display", "cam", "bars"])
    }

    @Test("the audio role includes microphones and audio generators")
    func audioRoleIncludesGenerators() {
        let choices = EngineModel.mediaChoices(from: discovered, producing: .audio)

        #expect(choices.map(\.id.rawValue) == ["tone", "mic"])
    }

    @Test("an input declaring no media is offered for no role")
    func undeclaredMediaIsOfferedForNothing() {
        let video = EngineModel.mediaChoices(from: discovered, producing: .video)
        let audio = EngineModel.mediaChoices(from: discovered, producing: .audio)

        #expect(!video.contains { $0.id.rawValue == "quiet" })
        #expect(!audio.contains { $0.id.rawValue == "quiet" })
    }

    @Test("choices come back in a stable name order, not discovery order")
    func choicesAreNameSorted() {
        let names = EngineModel.mediaChoices(from: discovered, producing: .video).map(\.name)

        #expect(names == ["Built-in Display", "FaceTime HD Camera", "SMPTE Bars"])
    }

    @Test("an input producing both media appears in both roles")
    func bothMediaAppearsInBothRoles() {
        let both = [
            MockInput(id: InputID(rawValue: "movie"), name: "Clip.mov", kind: .generator, media: [.video, .audio])
        ]

        #expect(EngineModel.mediaChoices(from: both, producing: .video).count == 1)
        #expect(EngineModel.mediaChoices(from: both, producing: .audio).count == 1)
    }

    @Test("an empty discovery list yields no choices")
    func emptyDiscoveryYieldsNothing() {
        #expect(EngineModel.mediaChoices(from: [], producing: .video).isEmpty)
        #expect(EngineModel.mediaChoices(from: [], producing: .audio).isEmpty)
    }
}
