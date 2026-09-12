//
//  SnapshotListingTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// What the Library's Snapshots tab lists and the Data pane counts
/// (ARCHITECTURE.md, "Snapshots").
@Suite("SnapshotListing")
struct SnapshotListingTests {
    /// A throwaway folder on disk.
    private static func makeFolder() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "tingra-listing-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Writes a file and stamps its modification date.
    private static func write(_ url: URL, modifiedAt date: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 16).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
    }

    @Test("Images directly in the folder, newest first — not other files, not subfolders, not hidden files")
    func listsImagesNewestFirst() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        try Self.write(folder.appending(path: "Tingra Program 2026-09-10 14.03.12.png"), modifiedAt: base)
        try Self.write(folder.appending(path: "Renamed.jpg"), modifiedAt: base.addingTimeInterval(60))
        try Self.write(
            folder.appending(path: "Tingra Preview 2026-09-10 14.05.00.png"), modifiedAt: base.addingTimeInterval(120))
        try Self.write(folder.appending(path: "notes.txt"), modifiedAt: base.addingTimeInterval(180))
        try Self.write(folder.appending(path: ".hidden.png"), modifiedAt: base.addingTimeInterval(240))
        try Self.write(folder.appending(path: "Older/Tingra Program 2026-09-01 09.00.00.png"), modifiedAt: base)

        let names = SnapshotListing.files(in: folder).map(\.url.lastPathComponent)

        #expect(
            names == [
                "Tingra Preview 2026-09-10 14.05.00.png", "Renamed.jpg", "Tingra Program 2026-09-10 14.03.12.png",
            ])
    }

    @Test("Snapshots in the same second list the suffixed one first")
    func sameSecondTieBreaksByName() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try Self.write(folder.appending(path: "Tingra Program 2026-09-10 14.03.12.png"), modifiedAt: date)
        try Self.write(folder.appending(path: "Tingra Program 2026-09-10 14.03.12 2.png"), modifiedAt: date)

        let names = SnapshotListing.files(in: folder).map(\.url.lastPathComponent)

        #expect(names == ["Tingra Program 2026-09-10 14.03.12 2.png", "Tingra Program 2026-09-10 14.03.12.png"])
    }

    @Test("A folder not yet created lists nothing")
    func missingFolderListsNothing() {
        let folder = URL.temporaryDirectory.appending(path: "tingra-listing-tests-\(UUID().uuidString)")
        #expect(SnapshotListing.files(in: folder).isEmpty)
    }

    @Test("Library rows for snapshots are file rows: no input, the file name, and a date with the time")
    func libraryRowsAreFileRows() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let url = folder.appending(path: "Tingra Program 2026-09-10 14.03.12.png")
        try Self.write(url, modifiedAt: date)

        let items = LibraryItem.snapshots(in: folder)

        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.inputID == nil)
        #expect(item.mediaID == nil)
        #expect(item.kind == .image)
        #expect(item.isAvailable)
        #expect(item.name == url.lastPathComponent)
        #expect(item.eventID == url.lastPathComponent)
        #expect(item.byteCount == 16)
        #expect(item.detail.hasPrefix(date.formatted(date: .abbreviated, time: .shortened)))
    }
}
