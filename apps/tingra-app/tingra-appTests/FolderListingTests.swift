//
//  FolderListingTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TingraApp

/// What the Library's file tabs list and the Data pane counts
/// (ARCHITECTURE.md, "Snapshots" and "The Recordings tab").
@Suite("FolderListing")
struct FolderListingTests {
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

        let names = FolderListing.files(in: folder, conformingTo: .image).map(\.url.lastPathComponent)

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

        let names = FolderListing.files(in: folder, conformingTo: .image).map(\.url.lastPathComponent)

        #expect(names == ["Tingra Program 2026-09-10 14.03.12 2.png", "Tingra Program 2026-09-10 14.03.12.png"])
    }

    @Test("A folder not yet created lists nothing")
    func missingFolderListsNothing() {
        let folder = URL.temporaryDirectory.appending(path: "tingra-listing-tests-\(UUID().uuidString)")
        #expect(FolderListing.files(in: folder, conformingTo: .image).isEmpty)
    }

    @Test("Movies directly in the folder, newest first — not images beside them, and not filtered by name")
    func listsMoviesNewestFirst() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        try Self.write(folder.appending(path: "Tingra 2026-09-12 10.00.00.mov"), modifiedAt: base)
        try Self.write(folder.appending(path: "Debrief.mp4"), modifiedAt: base.addingTimeInterval(60))
        try Self.write(folder.appending(path: "Tingra Program 2026-09-12 10.01.00.png"), modifiedAt: base)
        try Self.write(folder.appending(path: ".partial.mov"), modifiedAt: base.addingTimeInterval(120))
        try Self.write(folder.appending(path: "Old/Tingra 2026-09-01 09.00.00.mov"), modifiedAt: base)

        let movies = FolderListing.files(in: folder, conformingTo: .movie).map(\.url.lastPathComponent)
        let images = FolderListing.files(in: folder, conformingTo: .image).map(\.url.lastPathComponent)

        #expect(movies == ["Debrief.mp4", "Tingra 2026-09-12 10.00.00.mov"])
        #expect(images == ["Tingra Program 2026-09-12 10.01.00.png"])
    }

    @Test("Two spellings of one file are the same file, and two files are not")
    func sameFile() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Tingra 2026-09-12 10.00.00.mov")
        try Self.write(file, modifiedAt: .now)
        let listed = try #require(FolderListing.files(in: folder, conformingTo: .movie).first?.url)
        let dotted = URL(filePath: folder.path(percentEncoded: false) + "/./" + file.lastPathComponent)

        #expect(FolderListing.isSameFile(listed, file))
        #expect(FolderListing.isSameFile(dotted, file))
        #expect(!FolderListing.isSameFile(file, folder.appending(path: "Other.mov")))
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

    @Test("Library rows for recordings are movie file rows, with the take being written marked and first")
    func recordingRowsMarkTheTakeBeingWritten() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let finished = folder.appending(path: "Tingra 2026-09-12 10.00.00.mov")
        let rolling = folder.appending(path: "Tingra 2026-09-12 09.00.00.mov")
        try Self.write(finished, modifiedAt: base.addingTimeInterval(60))
        // Dated older on purpose: the take being written is first whatever
        // its modification date says.
        try Self.write(rolling, modifiedAt: base)

        let idle = LibraryItem.recordings(in: folder, recording: nil)
        let recording = LibraryItem.recordings(in: folder, recording: rolling)

        #expect(idle.map(\.name) == [finished.lastPathComponent, rolling.lastPathComponent])
        #expect(idle.allSatisfy { !$0.isRecording && $0.kind == .movie && $0.inputID == nil })
        #expect(recording.map(\.name) == [rolling.lastPathComponent, finished.lastPathComponent])
        #expect(recording.map(\.isRecording) == [true, false])
        let rollingDetail = try #require(recording.first).detail(knownDuration: 90)
        #expect(
            rollingDetail
                == String(
                    localized: "Recording…",
                    comment: "Library Recordings tab: detail line of the take being recorded now"))
        #expect(
            recording[1].detail.hasPrefix(
                recording[1].modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-"))
    }

    @Test("A recording in another folder marks no row")
    func recordingElsewhereMarksNothing() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.write(folder.appending(path: "Tingra 2026-09-12 10.00.00.mov"), modifiedAt: .now)

        let rows = LibraryItem.recordings(
            in: folder, recording: URL(filePath: "/Volumes/Elsewhere/Tingra 2026-09-12 10.00.00.mov"))

        #expect(rows.count == 1)
        #expect(rows.allSatisfy { !$0.isRecording })
    }
}
