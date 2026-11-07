//
//  WindowLayoutPreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// The main window's column visibility, persisted per Mac.
@Suite("WindowLayoutPreferences")
struct WindowLayoutPreferencesTests {
    /// A store over a throwaway defaults suite, so no test touches the
    /// developer's own window layout.
    private static func makeStore(suiteName: String) throws -> WindowLayoutPreferences {
        WindowLayoutPreferences(defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    @Test("the inspector column is shown on a fresh install")
    func inspectorShownByDefault() throws {
        let suiteName = "WindowLayoutPreferencesTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        #expect(try Self.makeStore(suiteName: suiteName).isInspectorPresented)
    }

    @Test("a hidden inspector column stays hidden for the next launch")
    func hiddenInspectorPersists() throws {
        let suiteName = "WindowLayoutPreferencesTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        try Self.makeStore(suiteName: suiteName).setInspectorPresented(false)

        // A second store over the same suite stands in for the next launch.
        #expect(try Self.makeStore(suiteName: suiteName).isInspectorPresented == false)
    }

    @Test("showing the inspector column again is remembered too")
    func shownInspectorPersists() throws {
        let suiteName = "WindowLayoutPreferencesTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = try Self.makeStore(suiteName: suiteName)

        store.setInspectorPresented(false)
        store.setInspectorPresented(true)

        #expect(try Self.makeStore(suiteName: suiteName).isInspectorPresented)
    }
}
