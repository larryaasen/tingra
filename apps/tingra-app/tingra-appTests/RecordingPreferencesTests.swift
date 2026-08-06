//
//  RecordingPreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraApp

@Suite("RecordingPreferences")
struct RecordingPreferencesTests {
    /// A preferences store over its own throwaway defaults suite, so a test
    /// never reads or writes the user's own settings.
    private func makePreferences() throws -> (RecordingPreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (RecordingPreferences(defaults: defaults), defaults, name)
    }

    @Test("a fresh install records to the Movies folder, which needs no TCC prompt")
    func freshInstallUsesMovies() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.folder == URL.moviesDirectory)
        #expect(RecordingPreferences.defaultFolder == URL.moviesDirectory)
    }

    @Test("a fresh install records QuickTime movies")
    func freshInstallUsesMov() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.container == .mov)
    }

    @Test("a chosen folder persists and is read back by a fresh store over the same defaults")
    func folderPersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        let folder = URL(filePath: "/Volumes/Shows/Tingra", directoryHint: .isDirectory)
        preferences.folder = folder
        #expect(RecordingPreferences(defaults: defaults).folder.path(percentEncoded: false) == folder.path())
    }

    @Test("a chosen container persists")
    func containerPersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.container = .mp4
        #expect(RecordingPreferences(defaults: defaults).container == .mp4)
    }

    @Test("an unrecognized stored container reads as the default rather than losing the recording")
    func unknownContainerFallsBack() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("mkv", forKey: "recording.container")
        #expect(preferences.container == RecordingPreferences.defaultContainer)
    }

    @Test("an empty stored folder reads as the default")
    func emptyFolderFallsBack() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("", forKey: "recording.folderPath")
        #expect(preferences.folder == RecordingPreferences.defaultFolder)
    }
}
