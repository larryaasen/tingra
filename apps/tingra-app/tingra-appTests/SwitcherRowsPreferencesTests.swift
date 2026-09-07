//
//  SwitcherRowsPreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

@Suite("SwitcherRowsPreferences")
struct SwitcherRowsPreferencesTests {
    /// A preferences store over its own throwaway defaults suite, so a test
    /// never reads or writes the user's own settings.
    private func makePreferences() throws -> (SwitcherRowsPreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (SwitcherRowsPreferences(defaults: defaults), defaults, name)
    }

    @Test("a fresh install hides the switcher rows")
    func freshInstallHidesTheRows() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(defaults.object(forKey: "switcherRows.visible") == nil)
        #expect(preferences.isVisible == false)
        #expect(SwitcherRowsPreferences.defaultIsVisible == false)
    }

    @Test("showing the rows persists and is read back by a fresh store over the same defaults")
    func shownRowsPersist() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.isVisible = true

        #expect(SwitcherRowsPreferences(defaults: defaults).isVisible)
    }

    @Test("hiding the rows again persists too, and is not mistaken for a missing value")
    func hiddenRowsPersist() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.isVisible = true
        preferences.isVisible = false

        #expect(defaults.object(forKey: "switcherRows.visible") != nil)
        #expect(SwitcherRowsPreferences(defaults: defaults).isVisible == false)
    }
}
