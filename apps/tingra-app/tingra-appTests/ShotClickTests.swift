//
//  ShotClickTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-11-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import SwiftUI
import Testing
import TingraComposition

@testable import TingraApp

/// A program that records which bus a pick moved.
@MainActor
private final class RecordingProgram: ProgramControlling {
    let shots: [Shot] = []
    var activeShotID: ShotID?
    var previewShotID: ShotID?
    let isFadedToBlack = false

    func take(_ shotID: ShotID) { activeShotID = shotID }
    func setPreview(_ shotID: ShotID) { previewShotID = shotID }
    func setFadeToBlack(_ faded: Bool, duration: TimeInterval) {}
}

/// The click rule behind every shot surface: which action a pick means in
/// each switching mode and under each modifier, the `tap` name each surface
/// reports for it, and the bus the action moves (ARCHITECTURE.md, "Taking a
/// shot with one click").
@MainActor
@Suite("Shot click")
struct ShotClickTests {
    /// Every combination of the four modifier keys a click can carry.
    nonisolated private static let modifierSets: [EventModifiers] = (0..<16).map { bits in
        var modifiers: EventModifiers = []
        if bits & 1 != 0 { modifiers.insert(.command) }
        if bits & 2 != 0 { modifiers.insert(.option) }
        if bits & 4 != 0 { modifiers.insert(.shift) }
        if bits & 8 != 0 { modifiers.insert(.control) }
        return modifiers
    }

    /// The shot on program before a pick.
    private let onProgram = ShotID(rawValue: "wide")

    /// The shot staged before a pick.
    private let staged = ShotID(rawValue: "close")

    /// The shot the operator picks.
    private let picked = ShotID(rawValue: "bars")

    /// A program with one shot on each bus.
    private func makeProgram() -> RecordingProgram {
        let program = RecordingProgram()
        program.activeShotID = onProgram
        program.previewShotID = staged
        return program
    }

    @Test("Stage on Preview stages under every modifier", arguments: modifierSets)
    func stageOnPreviewAlwaysStages(modifiers: EventModifiers) {
        #expect(ShotClick.action(mode: .stageOnPreview, modifiers: modifiers) == .stage)
    }

    @Test("Take to Program takes unless Option is held, whatever else is", arguments: modifierSets)
    func takeToProgramTakesUnlessOptionIsHeld(modifiers: EventModifiers) {
        let expected: ShotClickAction = modifiers.contains(.option) ? .stage : .take
        #expect(ShotClick.action(mode: .takeToProgram, modifiers: modifiers) == expected)
    }

    @Test("a plain click and a ⌘ shortcut take in Take to Program, and an Option-click stages")
    func theNamedCases() {
        #expect(ShotClick.action(mode: .takeToProgram, modifiers: []) == .take)
        #expect(ShotClick.action(mode: .takeToProgram, modifiers: .command) == .take)
        #expect(ShotClick.action(mode: .takeToProgram, modifiers: .option) == .stage)
        #expect(ShotClick.action(mode: .stageOnPreview, modifiers: []) == .stage)
        #expect(ShotClick.action(mode: .stageOnPreview, modifiers: .option) == .stage)
    }

    @Test("the mode's stored values are the ones the preferences already hold")
    func modeRawValuesAreStable() {
        #expect(SwitchingMode.stageOnPreview.rawValue == "stageOnPreview")
        #expect(SwitchingMode.takeToProgram.rawValue == "takeToProgram")
        #expect(SwitchingMode.allCases == [.stageOnPreview, .takeToProgram])
    }

    @Test("each surface keeps its stage tap name and reports a take under its own")
    func surfacesNameStagesAndTakesApart() {
        #expect(ShotClickSurface.shotBank.tapName(for: .stage) == "shotBank.tile")
        #expect(ShotClickSurface.shotBank.tapName(for: .take) == "shotBankTake.tile")
        #expect(ShotClickSurface.menuBar.tapName(for: .stage) == "shot.menuItem")
        #expect(ShotClickSurface.menuBar.tapName(for: .take) == "shotTake.menuItem")
        #expect(ShotClickSurface.sidebar.tapName(for: .stage) == "sidebarShot.row")
        #expect(ShotClickSurface.sidebar.tapName(for: .take) == "sidebarShotTake.row")
    }

    @Test("no two surfaces share a tap name, and no surface reuses one across actions")
    func tapNamesAreDistinct() {
        var names: Set<String> = []
        for surface in ShotClickSurface.allCases {
            for action in ShotClickAction.allCases {
                names.insert(surface.tapName(for: action))
            }
        }
        #expect(names.count == ShotClickSurface.allCases.count * ShotClickAction.allCases.count)
    }

    @Test(
        "a pick in Stage on Preview stages from every surface, leaving program alone",
        arguments: ShotClickSurface.allCases)
    func stageModePickStages(surface: ShotClickSurface) {
        let program = makeProgram()

        let click = ShotClick(on: surface, mode: .stageOnPreview, modifiers: [])
        program.perform(click.action, on: picked)

        #expect(click.action == .stage)
        #expect(click.tapName == surface.tapName(for: .stage))
        #expect(program.previewShotID == picked)
        #expect(program.activeShotID == onProgram)
    }

    @Test(
        "a pick in Take to Program takes from every surface, leaving preview staged",
        arguments: ShotClickSurface.allCases)
    func takeModePickTakes(surface: ShotClickSurface) {
        let program = makeProgram()

        let click = ShotClick(on: surface, mode: .takeToProgram, modifiers: [])
        program.perform(click.action, on: picked)

        #expect(click.action == .take)
        #expect(click.tapName == surface.tapName(for: .take))
        #expect(program.activeShotID == picked)
        #expect(program.previewShotID == staged)
    }

    @Test(
        "an Option pick in Take to Program stages from every surface, under the stage tap name",
        arguments: ShotClickSurface.allCases)
    func optionPickStagesInTakeMode(surface: ShotClickSurface) {
        let program = makeProgram()

        let click = ShotClick(on: surface, mode: .takeToProgram, modifiers: .option)
        program.perform(click.action, on: picked)

        #expect(click.action == .stage)
        #expect(click.tapName == surface.tapName(for: .stage))
        #expect(program.previewShotID == picked)
        #expect(program.activeShotID == onProgram)
    }

    @Test("clicks compare equal only when the action and the tap name match")
    func equality() {
        let take = ShotClick(on: .shotBank, mode: .takeToProgram, modifiers: [])
        #expect(take == ShotClick(on: .shotBank, mode: .takeToProgram, modifiers: .command))
        #expect(take != ShotClick(on: .shotBank, mode: .stageOnPreview, modifiers: []))
        #expect(take != ShotClick(on: .sidebar, mode: .takeToProgram, modifiers: []))
    }

    @Test("AppKit's modifier flags map to the same four SwiftUI modifiers")
    func appKitFlagsMap() {
        #expect(EventModifiers(NSEvent.ModifierFlags.option) == .option)
        #expect(EventModifiers(NSEvent.ModifierFlags.command) == .command)
        #expect(EventModifiers(NSEvent.ModifierFlags.shift) == .shift)
        #expect(EventModifiers(NSEvent.ModifierFlags.control) == .control)
        #expect(EventModifiers(NSEvent.ModifierFlags([.option, .command])) == [.option, .command])
        #expect(EventModifiers(NSEvent.ModifierFlags([])) == [])
        // Caps Lock and the function key are not click modifiers.
        #expect(EventModifiers(NSEvent.ModifierFlags([.capsLock, .function])) == [])
    }

    @Test("the model starts in Stage on Preview and records a change of mode for the next launch")
    func modelRecordsTheMode() throws {
        let suiteName = "ShotClickTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = EngineModel(
            monitor: SilentMonitor(), snapshotPreferences: SnapshotPreferences(defaults: defaults),
            recordingPreferences: RecordingPreferences(defaults: defaults))
        model.sessionPreferences = SessionPreferences(defaults: defaults)

        #expect(model.switchingMode == .stageOnPreview)

        model.switchingMode = .takeToProgram
        #expect(SessionPreferences(defaults: defaults).position.switchingMode == .takeToProgram)

        model.switchingMode = .stageOnPreview
        #expect(SessionPreferences(defaults: defaults).position.switchingMode == .stageOnPreview)
    }
}
