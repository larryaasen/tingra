//
//  AppearanceModelTests.swift
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

/// An appearance target that only records what was installed on it — the
/// stand-in for `NSApplication`, so these tests never repaint the test host.
@MainActor
final class RecordingAppearanceTarget: AppearanceTarget {
    /// The appearance last installed, or nil when the app is inheriting the
    /// system's.
    var appearance: NSAppearance? {
        didSet { installCount += 1 }
    }

    /// How many times an appearance has been installed, so a test can tell an
    /// install apart from a no-op.
    private(set) var installCount = 0

    /// Creates a target with nothing installed.
    init() {}
}

@MainActor
@Suite("AppearanceModel")
struct AppearanceModelTests {
    /// A model over its own defaults suite and its own recording target.
    ///
    /// - Parameter mode: The mode to store before the model reads it, standing
    ///   in for a previous launch's choice.
    /// - Returns: The model, its target, and the defaults suite to tear down.
    private func makeModel(
        seeding mode: AppearanceMode? = nil
    ) throws -> (AppearanceModel, RecordingAppearanceTarget, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let preferences = AppearancePreferences(defaults: defaults)
        if let mode { preferences.mode = mode }
        let target = RecordingAppearanceTarget()
        return (AppearanceModel(preferences: preferences, application: target), target, defaults, name)
    }

    @Test("the stored appearance is installed at launch, before any window is drawn")
    func storedAppearanceIsInstalledAtLaunch() throws {
        let (model, target, defaults, name) = try makeModel(seeding: .dark)
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(model.mode == .dark)
        #expect(target.appearance?.name == .darkAqua)
        #expect(target.installCount == 1)
    }

    @Test("changing the mode repaints the app and persists the choice together")
    func changingTheModeRepaintsAndPersists() throws {
        let (model, target, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }

        model.mode = .light

        #expect(target.appearance?.name == .aqua)
        #expect(AppearancePreferences(defaults: defaults).mode == .light)
    }

    @Test("returning to System clears the installed appearance")
    func returningToSystemClearsTheAppearance() throws {
        let (model, target, defaults, name) = try makeModel(seeding: .dark)
        defer { defaults.removePersistentDomain(forName: name) }

        model.mode = .system

        #expect(target.appearance == nil)
        #expect(AppearancePreferences(defaults: defaults).mode == .system)
    }

    @Test("choosing the mode already in force installs nothing further")
    func choosingTheSameModeIsANoOp() throws {
        let (model, target, defaults, name) = try makeModel(seeding: .light)
        defer { defaults.removePersistentDomain(forName: name) }
        let installsAtLaunch = target.installCount

        model.mode = .light

        #expect(target.installCount == installsAtLaunch)
        #expect(model.mode == .light)
    }
}
