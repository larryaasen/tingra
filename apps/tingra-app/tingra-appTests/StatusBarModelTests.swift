//
//  StatusBarModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

@Suite("StatusBarModel")
@MainActor
struct StatusBarModelTests {
    /// A model over its own throwaway defaults suite, so a test never reads or
    /// writes the user's own settings.
    private func makeModel() throws -> (StatusBarModel, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (StatusBarModel(preferences: StatusBarPreferences(defaults: defaults)), defaults, name)
    }

    @Test("a fresh install starts with the bar shown")
    func freshInstallStartsShown() throws {
        let (model, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(model.isVisible)
    }

    @Test("hiding the bar writes the choice through, so the next launch honors it")
    func hidingWritesThrough() throws {
        let (model, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }

        model.isVisible = false

        #expect(StatusBarPreferences(defaults: defaults).isVisible == false)
        #expect(StatusBarModel(preferences: StatusBarPreferences(defaults: defaults)).isVisible == false)
    }

    @Test("showing it again writes through too")
    func showingWritesThrough() throws {
        let (model, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }

        model.isVisible = false
        model.isVisible = true

        #expect(StatusBarPreferences(defaults: defaults).isVisible)
    }

    @Test("the model adopts a stored choice at launch rather than the default")
    func storedChoiceIsAdoptedAtLaunch() throws {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(false, forKey: "statusBar.visible")

        #expect(StatusBarModel(preferences: StatusBarPreferences(defaults: defaults)).isVisible == false)
    }
}
