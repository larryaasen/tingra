//
//  StreamHistoryStoreTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

/// The stream history's file: what it reads with no file, that it reads back
/// what it wrote, and what becomes of a file it cannot read.
@Suite("StreamHistoryStore")
struct StreamHistoryStoreTests {
    /// A store in a fresh temporary folder, removed when the test ends.
    struct Fixture {
        /// The folder, not yet on disk — a fresh install.
        let folder = URL.temporaryDirectory.appending(path: "tingra-streamhistory-\(UUID().uuidString)")

        /// The store under test.
        var store: StreamHistoryStore { StreamHistoryStore(directory: folder) }

        /// Whether a file exists.
        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        /// Writes text where the history file goes.
        func writeRaw(_ text: String) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: store.fileURL, atomically: true, encoding: .utf8)
        }

        /// Removes the folder.
        func tearDown() { try? FileManager.default.removeItem(at: folder) }
    }

    /// A session at a whole-second moment.
    static func entry(_ number: Int, length: TimeInterval? = 600) -> StreamHistoryEntry {
        let start = Date(timeIntervalSince1970: 1_791_000_000 + Double(number) * 86_400)
        return StreamHistoryEntry(
            number: number,
            startedAt: start,
            endedAt: length.map { start.addingTimeInterval($0) },
            endReason: length == nil ? nil : .stopped,
            destinations: ["Twitch"],
            width: 1920,
            height: 1080,
            frameRate: 30
        )
    }

    @Test("the file is stream-history.json in the folder")
    func fileLocation() {
        let fixture = Fixture()
        #expect(fixture.store.fileURL == fixture.folder.appending(path: "stream-history.json"))
        #expect(fixture.store.unreadableFileURL.lastPathComponent == "stream-history.json.unreadable")
    }

    @Test("with no file the history reads empty")
    func readsEmptyWithoutFile() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        #expect(try fixture.store.read().isEmpty)
    }

    @Test("a written history reads back unchanged, creating the folder on the way")
    func roundTrips() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let entries = [Self.entry(1), Self.entry(2, length: nil)]
        try fixture.store.write(entries)
        #expect(try fixture.store.read() == entries)
    }

    @Test("the file holds the sessions under one key")
    func fileShape() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.store.write([Self.entry(1)])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.fileURL))
        let contents = try #require(object as? [String: Any])
        #expect(Array(contents.keys) == ["sessions"])
        #expect((contents["sessions"] as? [Any])?.count == 1)
    }

    @Test("reading a file that is not a history throws")
    func unreadableThrows() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.writeRaw("{ not json")
        #expect(throws: (any Error).self) { try fixture.store.read() }
    }

    @Test("reading a history without its sessions key throws keyNotFound")
    func missingSessionsThrows() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.writeRaw("{}")
        do {
            _ = try fixture.store.read()
            Issue.record("reading a file without sessions returned a history")
        } catch DecodingError.keyNotFound(let missing, _) {
            #expect(missing.stringValue == "sessions")
        }
    }

    @Test("setting an unreadable file aside moves it, replacing an earlier one")
    func setsAside() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.writeRaw("first")
        try fixture.store.setAsideUnreadableFile()
        try fixture.writeRaw("second")
        try fixture.store.setAsideUnreadableFile()
        #expect(!fixture.exists(fixture.store.fileURL))
        #expect(try String(contentsOf: fixture.store.unreadableFileURL, encoding: .utf8) == "second")
    }

    @Test("removing deletes the file and its unreadable sibling, and is a no-op with neither")
    func removes() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.store.remove()
        try fixture.writeRaw("old")
        try fixture.store.setAsideUnreadableFile()
        try fixture.store.write([Self.entry(1)])
        try fixture.store.remove()
        #expect(!fixture.exists(fixture.store.fileURL))
        #expect(!fixture.exists(fixture.store.unreadableFileURL))
    }
}
