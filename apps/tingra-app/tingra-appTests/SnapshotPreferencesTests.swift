//
//  SnapshotPreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// Where the snapshots folder persists (ARCHITECTURE.md, "Snapshots").
@Suite("SnapshotPreferences")
struct SnapshotPreferencesTests {
    /// A throwaway defaults suite, so tests never touch the user's.
    private func makeDefaults() throws -> UserDefaults {
        let name = "SnapshotPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A fresh install saves into a dedicated folder under ~/Pictures")
    func defaultFolder() throws {
        let preferences = SnapshotPreferences(defaults: try makeDefaults())
        #expect(preferences.folder == SnapshotPreferences.defaultFolder)
        #expect(preferences.folder.lastPathComponent == "Tingra Snapshots")
        #expect(
            preferences.folder.deletingLastPathComponent().standardizedFileURL
                == URL.picturesDirectory.standardizedFileURL)
    }

    @Test("A chosen folder reads back")
    func chosenFolderRoundTrips() throws {
        let preferences = SnapshotPreferences(defaults: try makeDefaults())
        let chosen = URL(filePath: "/Volumes/Shows/Stills", directoryHint: .isDirectory)
        preferences.folder = chosen
        #expect(preferences.folder.path(percentEncoded: false) == chosen.path(percentEncoded: false))
    }

    @Test("An empty stored path reads as the default")
    func emptyPathIsTheDefault() throws {
        let defaults = try makeDefaults()
        defaults.set("", forKey: SnapshotPreferences.folderKey)
        #expect(SnapshotPreferences(defaults: defaults).folder == SnapshotPreferences.defaultFolder)
    }
}
