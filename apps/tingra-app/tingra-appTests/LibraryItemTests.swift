//
//  LibraryItemTests.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition
import TingraPlugInKit
import UniformTypeIdentifiers

@testable import TingraApp

@Suite("LibraryItem")
struct LibraryItemTests {
    @Test("A content type maps to a kind: movies, images, text, and everything else")
    func kindFromContentType() {
        #expect(LibraryItem.kind(of: .png) == .image)
        #expect(LibraryItem.kind(of: .jpeg) == .image)
        #expect(LibraryItem.kind(of: .quickTimeMovie) == .movie)
        #expect(LibraryItem.kind(of: .mpeg4Movie) == .movie)
        #expect(LibraryItem.kind(of: .plainText) == .text)
        #expect(LibraryItem.kind(of: UTType(filenameExtension: "md")) == .text)
        #expect(LibraryItem.kind(of: .pdf) == .other)
        #expect(LibraryItem.kind(of: nil) == .other)
    }

    @Test("Each kind has its own symbol")
    func kindSymbols() {
        let kinds: [LibraryItem.Kind] = [.image, .movie, .text, .other]
        #expect(Set(kinds.map(\.symbol)).count == kinds.count)
        #expect(LibraryItem.Kind.image.symbol == "photo")
        #expect(LibraryItem.Kind.movie.symbol == "film")
        #expect(LibraryItem.Kind.text.symbol == "doc.text")
    }

    @Test("The detail line shows the date, then the length, then the size — each only when known")
    func detailLine() {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let dateText = date.formatted(date: .abbreviated, time: .omitted)
        let sizeText = Int64(1_000_000).formatted(.byteCount(style: .file))
        let withDuration = LibraryItem.detail(modifiedAt: date, byteCount: 1_000_000, duration: 125)
        #expect(withDuration.hasPrefix(dateText + " · "))
        #expect(withDuration.contains("2:05"))
        #expect(withDuration.hasSuffix(" · " + sizeText))
        #expect(LibraryItem.detail(modifiedAt: nil, byteCount: nil, duration: 125) == "2:05")
        let withSize = LibraryItem.detail(modifiedAt: date, byteCount: 1_000_000, duration: nil)
        #expect(withSize.hasPrefix(dateText + " · "))
        #expect(withSize.contains("1"))
        #expect(!withSize.contains("2:05"))
        #expect(LibraryItem.detail(modifiedAt: nil, byteCount: nil, duration: nil).isEmpty)
        let withTime = LibraryItem.detail(modifiedAt: date, byteCount: 1_000_000, duration: nil, includesTime: true)
        #expect(withTime.hasPrefix(date.formatted(date: .abbreviated, time: .shortened) + " · "))
        #expect(
            LibraryItem.detail(modifiedAt: nil, byteCount: 2048, duration: nil)
                == Int64(2048).formatted(.byteCount(style: .file)))
    }

    @Test("Rows are built per media item, in order, with availability, kind, duration, and the file's facts")
    func itemsFromMedia() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let movie = ProjectMedia(id: MediaID(rawValue: "m-movie"), url: URL(filePath: "/tmp/clip.mov"))
        let image = ProjectMedia(
            id: MediaID(rawValue: "m-image"), url: URL(filePath: "/tmp/poster.png"), name: "Poster")
        let items = LibraryItem.items(
            from: [movie, image],
            durations: [movie.id: 42],
            isAvailable: { $0 == InputID(rawValue: "m-movie") },
            attributes: { url in url.lastPathComponent == "clip.mov" ? (date, 5_000) : (nil, nil) }
        )
        #expect(items.map(\.id) == [.media(movie.id), .media(image.id)])
        #expect(items.map(\.mediaID) == [movie.id, image.id])
        #expect(items[0].eventID == "m-movie")
        #expect(items[0].kind == .movie)
        #expect(items[0].isAvailable)
        #expect(items[0].duration == 42)
        #expect(items[0].modifiedAt == date)
        #expect(items[0].byteCount == 5_000)
        #expect(items[0].inputID == InputID(rawValue: "m-movie"))
        #expect(items[1].kind == .image)
        #expect(items[1].name == "Poster")
        #expect(!items[1].isAvailable)
        #expect(items[1].duration == nil)
        #expect(items[1].detail.isEmpty)
    }

    @Test("File facts come back nil for a file that is not there and real for one that is")
    func fileAttributes() throws {
        let missing = LibraryItem.fileAttributes(of: URL(filePath: "/nonexistent/tingra-library-tests/x.png"))
        #expect(missing.modifiedAt == nil)
        #expect(missing.byteCount == nil)
        let folder = URL.temporaryDirectory.appending(path: "tingra-library-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: file)
        let present = LibraryItem.fileAttributes(of: file)
        #expect(present.byteCount == 5)
        #expect(present.modifiedAt != nil)
    }

    @Test("A measured length fills in for a row that carries none, and never replaces one it carries")
    func knownDuration() {
        let carried = LibraryItem(
            id: .media(MediaID(rawValue: "m")), name: "clip.mov", url: URL(filePath: "/tmp/clip.mov"), kind: .movie,
            modifiedAt: nil, byteCount: nil, duration: 42, isAvailable: true)
        let bare = LibraryItem(
            id: .file(URL(filePath: "/tmp/take.mov")), name: "take.mov", url: URL(filePath: "/tmp/take.mov"),
            kind: .movie, modifiedAt: nil, byteCount: nil, duration: nil, isAvailable: true)
        #expect(carried.detail(knownDuration: 125) == "0:42")
        #expect(bare.detail(knownDuration: 125) == "2:05")
        #expect(bare.detail.isEmpty)
        #expect(!bare.isRecording)
    }

    @Test("Items compare equal when matching and unequal when a field differs")
    func equality() {
        let a = LibraryItem(
            id: .media(MediaID(rawValue: "m")), name: "a.png", url: URL(filePath: "/tmp/a.png"), kind: .image,
            modifiedAt: nil, byteCount: 1, duration: nil, isAvailable: true)
        let b = LibraryItem(
            id: .media(MediaID(rawValue: "m")), name: "a.png", url: URL(filePath: "/tmp/a.png"), kind: .image,
            modifiedAt: nil, byteCount: 1, duration: nil, isAvailable: false)
        let recording = LibraryItem(
            id: .media(MediaID(rawValue: "m")), name: "a.png", url: URL(filePath: "/tmp/a.png"), kind: .image,
            modifiedAt: nil, byteCount: 1, duration: nil, isAvailable: true, isRecording: true)
        #expect(a == a)
        #expect(a != b)
        #expect(a != recording)
    }
}
