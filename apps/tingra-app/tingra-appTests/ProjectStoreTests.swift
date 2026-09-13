//
//  ProjectStoreTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

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

/// Exercises a store made for one project file rather than the default
/// location — what the File menu's Open, New, and Save As make
/// (ARCHITECTURE.md, "Projects as documents").
@Suite("ProjectStore per file")
struct ProjectFileStoreTests {
    @Test("a store made for a file derives its directory and name from the file")
    func fileStoreLocation() {
        let url = URL(filePath: "/tmp/shows/Sunday Service.tingraproject")
        let store = ProjectStore(fileURL: url)
        #expect(store.fileURL == url)
        #expect(store.directoryURL == URL(filePath: "/tmp/shows", directoryHint: .isDirectory))
        #expect(store.name == "Sunday Service")
    }

    @Test("the default store is named Default and carries the project extension")
    func defaultStoreName() {
        let store = ProjectStore()
        #expect(store.name == "Default")
        #expect(store.fileURL.pathExtension == ProjectStore.fileExtension)
        #expect(store.fileURL.lastPathComponent == ProjectStore.fileName)
    }

    @Test("a project saved through a per-file store loads back unchanged from a fresh store over the same file")
    func fileStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Show.tingraproject")
        let project = Project(id: ProjectID(rawValue: "show-1"), presets: [Preset(name: "Live", shots: [])])
        try ProjectStore(fileURL: url).save(project)
        #expect(try ProjectStore(fileURL: url).load() == project)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
