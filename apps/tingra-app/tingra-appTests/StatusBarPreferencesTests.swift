//
//  StatusBarPreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

@Suite("StatusBarPreferences")
struct StatusBarPreferencesTests {
    /// A preferences store over its own throwaway defaults suite, so a test
    /// never reads or writes the user's own settings.
    private func makePreferences() throws -> (StatusBarPreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (StatusBarPreferences(defaults: defaults), defaults, name)
    }

    @Test("a fresh install shows the status bar")
    func freshInstallShowsTheBar() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        // `UserDefaults.bool` returns false for a missing key, so a shown
        // default is only correct if the presence of the key is checked first.
        #expect(defaults.object(forKey: "statusBar.visible") == nil)
        #expect(preferences.isVisible)
        #expect(StatusBarPreferences.defaultIsVisible)
    }

    @Test("hiding the bar persists and is read back by a fresh store over the same defaults")
    func hiddenBarPersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.isVisible = false

        #expect(StatusBarPreferences(defaults: defaults).isVisible == false)
    }

    @Test("showing the bar again persists too")
    func shownBarPersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.isVisible = false
        preferences.isVisible = true

        #expect(StatusBarPreferences(defaults: defaults).isVisible)
    }
}
