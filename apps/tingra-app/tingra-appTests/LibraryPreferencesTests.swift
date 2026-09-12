//
//  LibraryPreferencesTests.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

@Suite("LibraryPreferences")
struct LibraryPreferencesTests {
    /// A throwaway defaults suite, so tests never touch the user's.
    private func makeDefaults() throws -> UserDefaults {
        let name = "LibraryPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A fresh install opens the Library at the default height")
    func defaultHeight() throws {
        let preferences = LibraryPreferences(defaults: try makeDefaults())
        #expect(preferences.height() == LibraryPreferences.defaultHeight)
    }

    @Test("A set height reads back, and an unusable stored value falls back to the default")
    func heightRoundTrips() throws {
        let defaults = try makeDefaults()
        let preferences = LibraryPreferences(defaults: defaults)
        preferences.setHeight(310)
        #expect(preferences.height() == 310)
        defaults.set("tall", forKey: LibraryPreferences.heightKey)
        #expect(preferences.height() == LibraryPreferences.defaultHeight)
        defaults.set(-5.0, forKey: LibraryPreferences.heightKey)
        #expect(preferences.height() == LibraryPreferences.defaultHeight)
    }

    @Test("A fresh install opens on the Media tab, and a chosen tab reads back")
    func tabRoundTrips() throws {
        let preferences = LibraryPreferences(defaults: try makeDefaults())
        #expect(preferences.tab() == .media)
        preferences.setTab(.snapshots)
        #expect(preferences.tab() == .snapshots)
        preferences.setTab(.recordings)
        #expect(preferences.tab() == .recordings)
        preferences.setTab(.media)
        #expect(preferences.tab() == .media)
    }

    @Test("A stored tab this build does not know reads as Media")
    func unknownTabIsMedia() throws {
        let defaults = try makeDefaults()
        defaults.set("trash", forKey: LibraryPreferences.tabKey)
        #expect(LibraryPreferences(defaults: defaults).tab() == .media)
    }

    @Test("The tabs are Media, Snapshots, and Recordings, in that order, each persisted under its own name")
    func tabsInOrder() {
        #expect(LibraryTab.allCases == [.media, .snapshots, .recordings])
        #expect(LibraryTab.allCases.map(\.rawValue) == ["media", "snapshots", "recordings"])
    }

    @Test("Clamping keeps the Library above its minimum and the inspector above its minimum")
    func clamping() {
        let column: CGFloat = 800
        #expect(LibraryPreferences.clamped(50, in: column) == LibraryPreferences.minimumHeight)
        #expect(LibraryPreferences.clamped(300, in: column) == 300)
        #expect(LibraryPreferences.clamped(790, in: column) == column - LibraryPreferences.minimumInspectorHeight)
    }

    @Test("In a column too short for both minimums, the Library keeps its own minimum")
    func clampingInAShortColumn() {
        let short = LibraryPreferences.minimumHeight + LibraryPreferences.minimumInspectorHeight - 50
        #expect(LibraryPreferences.clamped(500, in: short) == LibraryPreferences.minimumHeight)
        #expect(LibraryPreferences.clamped(10, in: short) == LibraryPreferences.minimumHeight)
    }
}
