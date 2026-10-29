//
//  MixerViewTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import Testing

@testable import TingraApp

/// The room the mixer's strips leave under them for the scroller, so the
/// mutes at their foot stay clear of it while the strips scroll.
@Suite("MixerView scroller clearance")
struct MixerViewTests {
    @Test("an overlay scroller, drawn over the content, gets its own thickness of room under the strips")
    func overlayScrollerClearance() {
        let clearance = MixerView.scrollerClearance(for: .overlay)
        #expect(clearance == NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
        #expect(clearance > 0)
    }

    @Test("a legacy scroller, which has its own row below the content, gets no room")
    func legacyScrollerClearance() {
        #expect(MixerView.scrollerClearance(for: .legacy) == 0)
    }
}

/// The master mute's model state: a session latch, independent of fade to
/// black, never read back from anywhere at launch.
@Suite("EngineModel master mute")
@MainActor
struct MasterMuteModelTests {
    /// A model over throwaway preferences and a silent monitor, so the test
    /// touches no device and none of the developer's settings.
    private func makeModel(suiteName: String) throws -> EngineModel {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return EngineModel(
            monitor: SilentMonitor(), snapshotPreferences: SnapshotPreferences(defaults: defaults),
            recordingPreferences: RecordingPreferences(defaults: defaults))
    }

    @Test("a new model starts with the master open")
    func aNewModelStartsOpen() throws {
        let suiteName = "MasterMuteModelTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        #expect(try makeModel(suiteName: suiteName).isMasterMuted == false)
    }

    @Test("muting and unmuting the master flips the latch")
    func mutingFlipsTheLatch() throws {
        let suiteName = "MasterMuteModelTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)

        model.setMasterMuted(true)
        #expect(model.isMasterMuted)

        model.setMasterMuted(false)
        #expect(model.isMasterMuted == false)
    }

    @Test("bringing the program up from black leaves a muted master muted")
    func fadeToBlackLeavesTheMuteAlone() throws {
        let suiteName = "MasterMuteModelTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)

        model.setMasterMuted(true)
        model.setFadeToBlack(true, duration: 0)
        model.setFadeToBlack(false, duration: 0)

        #expect(model.isMasterMuted)
        #expect(model.isFadedToBlack == false)
    }

    @Test("the mute is not carried over: a second model on the same preferences starts open")
    func theMuteIsNotPersisted() throws {
        let suiteName = "MasterMuteModelTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        try makeModel(suiteName: suiteName).setMasterMuted(true)

        #expect(try makeModel(suiteName: suiteName).isMasterMuted == false)
    }
}
