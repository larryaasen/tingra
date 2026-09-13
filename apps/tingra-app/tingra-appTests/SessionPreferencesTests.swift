//
//  SessionPreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition

@testable import TingraApp

/// Exercises where the operator's position persists and how a launch
/// validates it against the document it loaded.
@Suite("SessionPreferences")
struct SessionPreferencesTests {
    /// A store over its own throwaway defaults suite.
    private func makePreferences() throws -> (SessionPreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (SessionPreferences(defaults: defaults), defaults, name)
    }

    /// Two presets: `show` with three shots, `break` with one.
    private var presets: [Preset] {
        [
            Preset(id: PresetID(rawValue: "show"), name: "Show", shots: ["wide", "camera", "pluge"].map(shot)),
            Preset(id: PresetID(rawValue: "break"), name: "Break", shots: [shot("bars")]),
        ]
    }

    /// A shot with the given id and no layers.
    private func shot(_ id: String) -> Shot {
        Shot(id: ShotID(rawValue: id), name: id, layers: [])
    }

    @Test("a fresh install records no position")
    func freshInstallHasNoPosition() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.position == .none)
        #expect(preferences.position.presetID == nil)
    }

    @Test("a position round-trips through a fresh store over the same defaults")
    func positionRoundTrips() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let position = SessionPosition(
            presetID: PresetID(rawValue: "show"),
            activeShotID: ShotID(rawValue: "wide"),
            previewShotID: ShotID(rawValue: "pluge"))

        preferences.position = position

        #expect(SessionPreferences(defaults: defaults).position == position)
    }

    @Test("the armed transition — kind, wipe edge, shader, and duration — round-trips with the position")
    func armedTransitionRoundTrips() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let position = SessionPosition(
            presetID: PresetID(rawValue: "show"),
            transitionKind: .wipe,
            wipeEdge: .top,
            shaderName: .blinds,
            transitionDuration: 1.25)

        preferences.position = position

        let read = SessionPreferences(defaults: defaults).position
        #expect(read == position)
        #expect(read.transitionKind == .wipe)
        #expect(read.wipeEdge == .top)
        #expect(read.shaderName == .blinds)
        #expect(read.transitionDuration == 1.25)
    }

    @Test("a duration that was never recorded reads nil, not zero")
    func unrecordedDurationReadsNil() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.position = SessionPosition(transitionKind: .dissolve)

        #expect(preferences.position.transitionDuration == nil)
        #expect(defaults.object(forKey: "session.transitionDuration") == nil)
    }

    @Test("a transition value the app no longer knows reads nil rather than trapping")
    func unknownTransitionReadsNil() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("teleport", forKey: "session.transitionKind")
        defaults.set("inside", forKey: "session.wipeEdge")
        defaults.set("plasma", forKey: "session.shaderName")
        defaults.set("fast", forKey: "session.transitionDuration")

        let read = preferences.position

        #expect(read.transitionKind == nil)
        #expect(read.wipeEdge == nil)
        #expect(read.shaderName == nil)
        #expect(read.transitionDuration == nil)
        #expect(SessionPosition.none.transitionKind == nil)
    }

    @Test("a nil id clears its key rather than leaving the last one behind")
    func nilClearsKey() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.position = SessionPosition(
            presetID: PresetID(rawValue: "show"),
            activeShotID: ShotID(rawValue: "wide"),
            previewShotID: ShotID(rawValue: "pluge"))

        preferences.position = SessionPosition(presetID: PresetID(rawValue: "show"))

        #expect(preferences.position == SessionPosition(presetID: PresetID(rawValue: "show")))
        #expect(defaults.object(forKey: "session.activeShotID") == nil)
        #expect(defaults.object(forKey: "session.previewShotID") == nil)
    }

    @Test("the launch adopts the recorded preset while the document holds it")
    func launchAdoptsRecordedPreset() {
        let position = SessionPosition(presetID: PresetID(rawValue: "break"))
        #expect(position.launchPreset(in: presets)?.id.rawValue == "break")
    }

    @Test("the launch falls back to the first preset when the recorded one is gone or none was recorded")
    func launchFallsBackToFirstPreset() {
        let gone = SessionPosition(presetID: PresetID(rawValue: "deleted"))
        #expect(gone.launchPreset(in: presets)?.id.rawValue == "show")
        #expect(SessionPosition.none.launchPreset(in: presets)?.id.rawValue == "show")
        #expect(SessionPosition.none.launchPreset(in: []) == nil)
    }

    @Test("the recorded shots are restored while they exist in the adopted preset's pool")
    func recordedShotsRestoreWithinPool() throws {
        let position = SessionPosition(
            presetID: PresetID(rawValue: "show"),
            activeShotID: ShotID(rawValue: "camera"),
            previewShotID: ShotID(rawValue: "pluge"))
        let preset = try #require(position.launchPreset(in: presets))

        let shots = position.shots(validIn: preset)

        #expect(shots.program?.rawValue == "camera")
        #expect(shots.preview?.rawValue == "pluge")
    }

    @Test("a shot no longer in the pool is dropped on its own, and the other survives")
    func missingShotDropsAlone() throws {
        let position = SessionPosition(
            presetID: PresetID(rawValue: "show"),
            activeShotID: ShotID(rawValue: "deleted"),
            previewShotID: ShotID(rawValue: "pluge"))
        let preset = try #require(position.launchPreset(in: presets))

        let shots = position.shots(validIn: preset)

        #expect(shots.program == nil)
        #expect(shots.preview?.rawValue == "pluge")
    }

    @Test("shots recorded in a preset that is gone do not carry into the fallback preset unless it holds them too")
    func shotsDoNotCrossPresets() throws {
        let position = SessionPosition(
            presetID: PresetID(rawValue: "deleted"),
            activeShotID: ShotID(rawValue: "bars"),
            previewShotID: ShotID(rawValue: "wide"))
        let preset = try #require(position.launchPreset(in: presets))

        let shots = position.shots(validIn: preset)

        #expect(preset.id.rawValue == "show")
        #expect(shots.program == nil)
        #expect(shots.preview?.rawValue == "wide")
    }

    @Test("positions compare equal only when every id matches")
    func equality() {
        let a = SessionPosition(presetID: PresetID(rawValue: "show"), activeShotID: ShotID(rawValue: "wide"))
        let b = SessionPosition(presetID: PresetID(rawValue: "show"), activeShotID: ShotID(rawValue: "wide"))
        let c = SessionPosition(presetID: PresetID(rawValue: "show"), activeShotID: ShotID(rawValue: "camera"))
        #expect(a == b)
        #expect(a != c)
        #expect(a != .none)
    }
}

/// Exercises the per-project scope the store gained when projects became
/// documents (ARCHITECTURE.md, "Projects as documents"): each show keeps
/// its own position, the switcher's transition stays global, and the last
/// opened project is remembered.
@Suite("SessionPreferences per project")
struct SessionPreferencesScopeTests {
    /// A store over its own throwaway defaults suite.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("two projects keep their bus positions apart")
    func positionsAreScopedByProject() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let show = SessionPreferences(defaults: defaults, projectID: ProjectID(rawValue: "show"))
        let rehearsal = SessionPreferences(defaults: defaults, projectID: ProjectID(rawValue: "rehearsal"))

        show.position = SessionPosition(presetID: PresetID(rawValue: "a"), activeShotID: ShotID(rawValue: "wide"))
        rehearsal.position = SessionPosition(presetID: PresetID(rawValue: "b"), previewShotID: ShotID(rawValue: "bars"))

        #expect(show.position.presetID == PresetID(rawValue: "a"))
        #expect(show.position.activeShotID == ShotID(rawValue: "wide"))
        #expect(show.position.previewShotID == nil)
        #expect(rehearsal.position.presetID == PresetID(rawValue: "b"))
        #expect(rehearsal.position.activeShotID == nil)
        #expect(rehearsal.position.previewShotID == ShotID(rawValue: "bars"))
    }

    @Test("the armed transition is shared across project scopes")
    func transitionIsGlobal() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let show = SessionPreferences(defaults: defaults, projectID: ProjectID(rawValue: "show"))
        show.position = SessionPosition(transitionKind: .wipe, wipeEdge: .left, transitionDuration: 2)

        let other = show.scoped(to: ProjectID(rawValue: "other"))
        #expect(other.projectID == ProjectID(rawValue: "other"))
        #expect(other.position.transitionKind == .wipe)
        #expect(other.position.wipeEdge == .left)
        #expect(other.position.transitionDuration == 2)
        #expect(other.position.presetID == nil)
    }

    @Test("an unscoped store reads the flat keys of the one-project era, which a scoped store does not see")
    func unscopedStoreUsesFlatKeys() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let flat = SessionPreferences(defaults: defaults)
        flat.position = SessionPosition(presetID: PresetID(rawValue: "old"))

        #expect(defaults.string(forKey: "session.activePresetID") == "old")
        #expect(flat.scoped(to: nil).position.presetID == PresetID(rawValue: "old"))
        #expect(flat.scoped(to: ProjectID(rawValue: "new")).position.presetID == nil)
    }

    @Test("the last opened project round-trips, and nil removes it")
    func lastProjectRoundTrips() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = SessionPreferences(defaults: defaults)
        #expect(preferences.lastProjectURL == nil)

        let url = URL(filePath: "/Users/operator/Shows/Sunday.tingraproject")
        preferences.lastProjectURL = url
        #expect(SessionPreferences(defaults: defaults, projectID: ProjectID(rawValue: "x")).lastProjectURL == url)

        preferences.lastProjectURL = nil
        #expect(preferences.lastProjectURL == nil)
        #expect(defaults.object(forKey: "session.projectPath") == nil)
    }
}
