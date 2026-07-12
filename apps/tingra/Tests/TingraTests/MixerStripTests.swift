//
//  MixerStripTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
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
        let strip = MixerStrip(id: InputID(rawValue: "mic-1"), name: "Mic", level: 1, isMuted: false)
        var same = strip
        #expect(strip == same)
        same.level = 0.5
        #expect(strip != same)
    }
}
