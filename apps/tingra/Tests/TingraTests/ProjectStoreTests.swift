//
//  ProjectStoreTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition
import TingraPlugInKit

@testable import Tingra

/// Exercises the app's project document store against a temporary directory:
/// real save/load round trips, the missing-file and unreadable-file paths,
/// and the set-aside that protects user data from being silently overwritten
/// (see ARCHITECTURE.md, "Project save/load").
@Suite("ProjectStore")
struct ProjectStoreTests {
    /// A project with one single-shot preset, for round-trip coverage.
    private var sampleProject: Project {
        Project(
            presets: [
                Preset(
                    id: PresetID(rawValue: "default"),
                    name: "Default",
                    shots: [
                        Shot(
                            id: ShotID(rawValue: "pip"),
                            name: "Picture in Picture",
                            layers: ProgramLayout.layers(
                                displayID: InputID(rawValue: "display-1"),
                                cameraID: InputID(rawValue: "camera-1")
                            )
                        )
                    ]
                )
            ]
        )
    }

    /// Creates a store rooted in a fresh temporary directory (created lazily
    /// by the store's own save) so tests never touch the user's project file.
    private func makeStore() -> ProjectStore {
        ProjectStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    /// Removes a test store's directory.
    private func cleanUp(_ store: ProjectStore) {
        try? FileManager.default.removeItem(at: store.directoryURL)
    }

    @Test("a saved project loads back unchanged")
    func saveLoadRoundTrips() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        try store.save(sampleProject)
        #expect(try store.load() == sampleProject)
    }

    @Test("loading with no project file returns nil")
    func loadWithNoFileReturnsNil() throws {
        let store = makeStore()
        #expect(try store.load() == nil)
    }

    @Test("saving twice overwrites the document in place")
    func saveOverwrites() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        try store.save(sampleProject)
        let updated = Project(presets: [Preset(id: PresetID(rawValue: "default"), name: "Renamed")])
        try store.save(updated)
        #expect(try store.load() == updated)
    }

    @Test("loading a file that is not a project document throws")
    func loadUnreadableFileThrows() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("not a project".utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) {
            try store.load()
        }
    }

    @Test("setting an unreadable file aside moves it next to the original, freeing the path")
    func setAsideMovesTheFile() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        let garbage = Data("not a project".utf8)
        try garbage.write(to: store.fileURL)
        let setAside = try store.setAsideUnreadableFile()
        #expect(setAside.lastPathComponent == "Default.tingraproject.unreadable")
        #expect(try Data(contentsOf: setAside) == garbage)
        #expect(try store.load() == nil)
    }

    @Test("setting aside replaces a previous set-aside file")
    func setAsideReplacesPrevious() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("older garbage".utf8).write(to: store.fileURL)
        try store.setAsideUnreadableFile()
        let newer = Data("newer garbage".utf8)
        try newer.write(to: store.fileURL)
        let setAside = try store.setAsideUnreadableFile()
        #expect(try Data(contentsOf: setAside) == newer)
    }

    @Test("the store's file lives under the given directory with the project extension")
    func fileLocation() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tingra-store-location")
        let store = ProjectStore(directory: directory)
        #expect(store.fileURL.lastPathComponent == "Default.tingraproject")
        #expect(store.directoryURL == directory)
        #expect(store.fileURL == directory.appending(path: "Default.tingraproject"))
    }
}
