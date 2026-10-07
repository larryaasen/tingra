//
//  KeepAwakePreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraHost

@testable import TingraApp

@Suite("KeepAwakePreferences")
struct KeepAwakePreferencesTests {
    /// A preferences store over its own throwaway defaults suite, so a test
    /// never reads or writes the user's own settings.
    private func makePreferences() throws -> (KeepAwakePreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (KeepAwakePreferences(defaults: defaults), defaults, name)
    }

    @Test("a fresh install keeps the Mac awake")
    func freshInstallKeepsAwake() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        // `UserDefaults.bool` returns false for a missing key, so an on
        // default is only correct if the presence of the key is checked first.
        #expect(defaults.object(forKey: "keepAwake.enabled") == nil)
        #expect(preferences.isEnabled)
        #expect(KeepAwakePreferences.defaultIsEnabled)
    }

    @Test("turning it off persists and is read back by a fresh store over the same defaults")
    func offPersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.isEnabled = false

        #expect(KeepAwakePreferences(defaults: defaults).isEnabled == false)
    }

    @Test("turning it back on persists too")
    func onPersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.isEnabled = false
        preferences.isEnabled = true

        #expect(KeepAwakePreferences(defaults: defaults).isEnabled)
    }
}

/// A keep-awake that counts the holds asked of it and how many are out.
private final class CountingKeepAwake: KeepAwake, Sendable {
    /// The counters.
    private struct Counts: Sendable {
        /// How many holds were taken.
        var holds = 0
        /// How many were released.
        var releases = 0
    }

    /// One counted hold.
    private struct Hold: KeepAwakeHold {
        /// Reports the release.
        let onRelease: @Sendable () -> Void

        func release() { onRelease() }
    }

    /// The counters, shared with every hold handed out.
    private let counts = Mutex(Counts())

    func hold(reason: String) -> any KeepAwakeHold {
        counts.withLock { $0.holds += 1 }
        return Hold { [weak self] in self?.counts.withLock { $0.releases += 1 } }
    }

    /// How many holds were taken.
    var holds: Int { counts.withLock { $0.holds } }

    /// How many holds are still out.
    var liveHolds: Int { counts.withLock { $0.holds - $0.releases } }
}

/// The switch that owns the app's one hold: held exactly while a session is
/// running and the setting is on, whichever of the two changes.
@MainActor
@Suite("KeepAwakeSwitch")
struct KeepAwakeSwitchTests {
    /// A switch over a counting keep-awake and its own bus.
    private func makeSwitch(isEnabled: Bool) -> (KeepAwakeSwitch, CountingKeepAwake, EventBus) {
        let keepAwake = CountingKeepAwake()
        let eventBus = EventBus()
        return (KeepAwakeSwitch(keepAwake: keepAwake, eventBus: eventBus, isEnabled: isEnabled), keepAwake, eventBus)
    }

    @Test("nothing is held while no session is running")
    func idleHoldsNothing() {
        let (keepAwakeSwitch, keepAwake, _) = makeSwitch(isEnabled: true)

        #expect(keepAwakeSwitch.isHolding == false)
        #expect(keepAwake.holds == 0)
    }

    @Test("a session starting takes the hold and its ending releases it")
    func sessionTakesAndReleases() {
        let (keepAwakeSwitch, keepAwake, _) = makeSwitch(isEnabled: true)

        keepAwakeSwitch.isSessionRunning = true
        #expect(keepAwakeSwitch.isHolding)
        #expect(keepAwake.liveHolds == 1)

        keepAwakeSwitch.isSessionRunning = false
        #expect(keepAwakeSwitch.isHolding == false)
        #expect(keepAwake.liveHolds == 0)
    }

    @Test("with the setting off, a session takes no hold")
    func offTakesNothing() {
        let (keepAwakeSwitch, keepAwake, _) = makeSwitch(isEnabled: false)

        keepAwakeSwitch.isSessionRunning = true

        #expect(keepAwakeSwitch.isHolding == false)
        #expect(keepAwake.holds == 0)
    }

    @Test("turning the setting off mid-session releases the hold at once")
    func turningOffMidSessionReleases() {
        let (keepAwakeSwitch, keepAwake, _) = makeSwitch(isEnabled: true)
        keepAwakeSwitch.isSessionRunning = true

        keepAwakeSwitch.isEnabled = false

        #expect(keepAwakeSwitch.isHolding == false)
        #expect(keepAwake.liveHolds == 0)
    }

    @Test("turning the setting on mid-session takes the hold at once")
    func turningOnMidSessionHolds() {
        let (keepAwakeSwitch, keepAwake, _) = makeSwitch(isEnabled: false)
        keepAwakeSwitch.isSessionRunning = true

        keepAwakeSwitch.isEnabled = true

        #expect(keepAwakeSwitch.isHolding)
        #expect(keepAwake.liveHolds == 1)
    }

    @Test("a second session starting while one runs takes no second hold")
    func oneHoldForBothSessions() {
        let (keepAwakeSwitch, keepAwake, _) = makeSwitch(isEnabled: true)

        keepAwakeSwitch.isSessionRunning = true
        keepAwakeSwitch.isSessionRunning = true

        #expect(keepAwake.holds == 1)
    }

    @Test("each take and each release is traced once on the bus")
    func tracedOnTheBus() async {
        let (keepAwakeSwitch, _, eventBus) = makeSwitch(isEnabled: true)
        let stream = eventBus.events()

        keepAwakeSwitch.isSessionRunning = true
        keepAwakeSwitch.isEnabled = false
        keepAwakeSwitch.isEnabled = true
        keepAwakeSwitch.isSessionRunning = false
        eventBus.shutdown()
        var names: [String] = []
        for await event in stream where event.group == .trace { names.append(event.name) }

        #expect(names == ["keepAwake.held", "keepAwake.released", "keepAwake.held", "keepAwake.released"])
    }
}

/// The model's Keep Mac Awake setting: that it starts from the stored
/// choice, persists a change, and reports it. The engine is never started
/// and no power assertion is taken.
@MainActor
@Suite("EngineModel keep awake")
struct KeepAwakeModelTests {
    /// A model over a throwaway defaults suite and a counting keep-awake.
    private func makeModel() throws -> (EngineModel, CountingKeepAwake, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let keepAwake = CountingKeepAwake()
        let model = EngineModel(
            monitor: SilentMonitor(),
            keepAwakePreferences: KeepAwakePreferences(defaults: defaults),
            keepAwake: keepAwake
        )
        return (model, keepAwake, defaults, name)
    }

    @Test("a fresh model has the setting on and, with no session running, holds nothing")
    func onByDefault() throws {
        let (model, keepAwake, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(model.keepsMacAwake)
        #expect(model.isHoldingMacAwake == false)
        #expect(keepAwake.holds == 0)
    }

    @Test("turning the setting off persists the choice")
    func offPersists() throws {
        let (model, _, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }

        model.setKeepsMacAwake(false)

        #expect(model.keepsMacAwake == false)
        #expect(KeepAwakePreferences(defaults: defaults).isEnabled == false)
    }

    @Test("a model created over a stored off choice starts off")
    func storedChoiceIsRead() throws {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        KeepAwakePreferences(defaults: defaults).isEnabled = false

        let model = EngineModel(
            monitor: SilentMonitor(),
            keepAwakePreferences: KeepAwakePreferences(defaults: defaults),
            keepAwake: CountingKeepAwake()
        )

        #expect(model.keepsMacAwake == false)
    }

    @Test("changing the setting is reported once on the bus, and setting the same value is not")
    func changeIsReported() async throws {
        let (model, _, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }

        let stream = model.eventBus.events()
        model.setKeepsMacAwake(true)
        model.setKeepsMacAwake(false)
        model.eventBus.shutdown()
        var changes: [EventBusEvent] = []
        for await event in stream where event.name == "keepAwake.settingChanged" { changes.append(event) }

        #expect(changes.count == 1)
        #expect(changes.first?.params?["enabled"] == .bool(false))
    }
}
