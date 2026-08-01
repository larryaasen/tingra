//
//  MonitorPreferencesTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import Tingra

@Suite("MonitorPreferences")
struct MonitorPreferencesTests {
    /// A preferences store over its own throwaway defaults suite, so a test
    /// never reads or writes the user's own settings.
    private func makePreferences() throws -> (MonitorPreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (MonitorPreferences(defaults: defaults), defaults, name)
    }

    @Test("monitoring starts off — a fresh install selects no device")
    func monitoringStartsOff() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.deviceUID == nil)
    }

    @Test("an unset level reads the audible default, not silence")
    func unsetLevelIsAudible() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.level == MonitorPreferences.defaultLevel)
        #expect(preferences.level > 0)
    }

    @Test("a chosen device persists and is read back by a fresh store over the same defaults")
    func devicePersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.deviceUID = "BuiltInHeadphoneOutputDevice"

        let reopened = MonitorPreferences(defaults: defaults)
        #expect(reopened.deviceUID == "BuiltInHeadphoneOutputDevice")
    }

    @Test("deselecting a device clears the stored selection")
    func deselectingClearsTheSelection() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.deviceUID = "uid-1"
        preferences.deviceUID = nil

        #expect(MonitorPreferences(defaults: defaults).deviceUID == nil)
    }

    @Test("a stored level round-trips, including an explicit silence")
    func levelRoundTrips() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.level = 0.35
        #expect(abs(MonitorPreferences(defaults: defaults).level - 0.35) < 0.0001)

        // An explicit zero must read back as zero rather than falling
        // through to the unset default.
        preferences.level = 0
        #expect(MonitorPreferences(defaults: defaults).level == 0)
    }

    @Test("a level outside the range is clamped on the way in and on the way out")
    func levelIsClamped() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.level = 4
        #expect(preferences.level == 1)

        preferences.level = -1
        #expect(preferences.level == 0)

        // A value written by something other than this store is clamped on
        // read, so a hand-edited preference can never boost the monitor.
        defaults.set(9.0, forKey: "monitor.level")
        #expect(preferences.level == 1)
    }

    @Test("the selected device's name round-trips, so the picker can label an absent selection")
    func deviceNameRoundTrips() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.deviceName == nil)

        preferences.deviceUID = "uid-1"
        preferences.deviceName = "Vocaster One USB"
        #expect(MonitorPreferences(defaults: defaults).deviceName == "Vocaster One USB")
    }

    @Test("deselecting a device clears the cached name with the selection it labelled")
    func deselectingClearsTheName() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.deviceUID = "uid-1"
        preferences.deviceName = "Vocaster One USB"

        preferences.deviceUID = nil
        preferences.deviceName = nil
        #expect(MonitorPreferences(defaults: defaults).deviceName == nil)
    }
}
