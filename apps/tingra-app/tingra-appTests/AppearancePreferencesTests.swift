//
//  AppearancePreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import Testing

@testable import TingraApp

@Suite("AppearancePreferences")
struct AppearancePreferencesTests {
    /// A preferences store over its own throwaway defaults suite, so a test
    /// never reads or writes the user's own settings.
    private func makePreferences() throws -> (AppearancePreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AppearancePreferences(defaults: defaults), defaults, name)
    }

    @Test("a fresh install follows the system")
    func freshInstallFollowsTheSystem() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.mode == .system)
        #expect(AppearancePreferences.defaultMode == .system)
    }

    @Test("a chosen mode persists and is read back by a fresh store over the same defaults")
    func chosenModePersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.mode = .dark

        let reopened = AppearancePreferences(defaults: defaults)
        #expect(reopened.mode == .dark)
    }

    @Test("every mode round-trips through the defaults database")
    func everyModeRoundTrips() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        for mode in AppearanceMode.allCases {
            preferences.mode = mode
            #expect(AppearancePreferences(defaults: defaults).mode == mode)
        }
    }

    @Test("a stored value this build does not recognize reads as System")
    func unrecognizedStoredValueFollowsTheSystem() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("sepia", forKey: "appearance.mode")

        #expect(preferences.mode == .system)
    }

    @Test("System installs no appearance, so the app inherits the system's")
    func systemInheritsRatherThanOverrides() {
        #expect(AppearanceMode.system.appearance == nil)
    }

    @Test("Light and Dark install the matching AppKit appearances")
    func lightAndDarkInstallTheirAppearances() {
        #expect(AppearanceMode.light.appearance?.name == .aqua)
        #expect(AppearanceMode.dark.appearance?.name == .darkAqua)
    }

    @Test("the picker offers exactly System, Light, and Dark, in that order")
    func modesAreOfferedInTheSystemOrder() {
        #expect(AppearanceMode.allCases == [.system, .light, .dark])
    }
}
