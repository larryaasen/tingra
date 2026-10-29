//
//  CameraPresetStoreTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

/// The camera presets' file: what it reads with no file, that it reads back
/// what it wrote, and what becomes of a file it cannot read.
@Suite("CameraPresetStore")
struct CameraPresetStoreTests {
    /// A store in a fresh temporary folder, removed when the test ends.
    struct Fixture {
        /// The folder, not yet on disk — a fresh install.
        let folder = URL.temporaryDirectory.appending(path: "tingra-camerapresets-\(UUID().uuidString)")

        /// The store under test.
        var store: CameraPresetStore { CameraPresetStore(directory: folder) }

        /// Whether a file exists.
        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        /// Writes text where the presets file goes.
        func writeRaw(_ text: String) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: store.fileURL, atomically: true, encoding: .utf8)
        }

        /// Removes the folder.
        func tearDown() { try? FileManager.default.removeItem(at: folder) }
    }

    /// Two presets, the second the default.
    static func twoPresets() -> CameraPresets {
        var presets = CameraPresets()
        presets.save(name: "Desk", cameraID: "a", cameraName: "A", values: ["brightness": 95, "autoFocus": true])
        let wide = presets.save(name: "Wide", cameraID: "b", cameraName: "B", values: ["zoom": 100])
        if let wide {
            presets.makeDefault(wide.id)
        }
        return presets
    }

    @Test("the file is camera-presets.json in the folder")
    func fileLocation() {
        let fixture = Fixture()
        #expect(fixture.store.fileURL == fixture.folder.appending(path: "camera-presets.json"))
        #expect(fixture.store.unreadableFileURL.lastPathComponent == "camera-presets.json.unreadable")
    }

    @Test("with no file there are no presets and no default")
    func readsEmptyWithoutFile() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let presets = try fixture.store.read()
        #expect(presets.isEmpty)
        #expect(presets.defaultPresetID == nil)
    }

    @Test("written presets read back unchanged, default included, creating the folder on the way")
    func roundTrips() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let presets = Self.twoPresets()
        try fixture.store.write(presets)
        #expect(try fixture.store.read() == presets)
    }

    @Test("a file that is not camera presets throws on read")
    func unreadableThrows() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.writeRaw("not json")
        #expect(throws: (any Error).self) { try fixture.store.read() }
    }

    @Test("an unreadable file is set aside, replacing an earlier one, and reading then starts empty")
    func setAside() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.writeRaw("first")
        try fixture.store.setAsideUnreadableFile()
        try fixture.writeRaw("second")
        try fixture.store.setAsideUnreadableFile()
        #expect(!fixture.exists(fixture.store.fileURL))
        #expect(try String(contentsOf: fixture.store.unreadableFileURL, encoding: .utf8) == "second")
        #expect(try fixture.store.read().isEmpty)
    }
}
