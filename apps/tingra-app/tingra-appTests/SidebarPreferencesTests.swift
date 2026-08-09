//
//  SidebarPreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

@Suite("SidebarPreferences")
struct SidebarPreferencesTests {
    /// A preferences store over its own throwaway defaults suite, so a test
    /// never reads or writes the user's own settings.
    private func makePreferences() throws -> (SidebarPreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (SidebarPreferences(defaults: defaults), defaults, name)
    }

    @Test("a fresh install shows every section open", arguments: SidebarSection.allCases)
    func freshInstallIsFullyExpanded(section: SidebarSection) throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        // `UserDefaults.bool` returns false for a missing key, so an open
        // default has to be the *absence* of a value, not its content.
        #expect(preferences.isExpanded(section))
    }

    @Test("a fresh install reports every section as expanded")
    func freshInstallExpandedSetIsComplete() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.expandedSections() == Set(SidebarSection.allCases))
    }

    @Test("a collapsed section persists and is read back by a fresh store over the same defaults")
    func collapsePersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.setExpanded(false, for: .cameras)

        #expect(!SidebarPreferences(defaults: defaults).isExpanded(.cameras))
    }

    @Test("collapsing one section leaves the others open")
    func collapseIsPerSection() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.setExpanded(false, for: .audioOutputs)

        #expect(preferences.expandedSections() == Set(SidebarSection.allCases).subtracting([.audioOutputs]))
    }

    @Test("reopening a collapsed section persists too")
    func reopenPersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.setExpanded(false, for: .shots)
        preferences.setExpanded(true, for: .shots)

        #expect(SidebarPreferences(defaults: defaults).isExpanded(.shots))
    }

    @Test("every section persists under its own key")
    func keysAreDistinct() {
        let keys = SidebarSection.allCases.map(\.expansionKey)

        #expect(Set(keys).count == SidebarSection.allCases.count)
        #expect(keys.allSatisfy { $0.hasPrefix("sidebar.") })
    }

    @Test("every section reports its own tap name")
    func tapNamesAreDistinct() {
        let names = SidebarSection.allCases.map(\.tapName)

        // One name per disclosure rather than a shared name told apart by a
        // param, so each section's use is traceable on its own.
        #expect(Set(names).count == SidebarSection.allCases.count)
        #expect(names.allSatisfy { $0.hasSuffix(".disclosure") })
    }
}
