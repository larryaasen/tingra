//
//  SnapshotFilenameTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// The naming rule that says what a snapshot is of and when, and never
/// overwrites one (ARCHITECTURE.md, "Snapshots").
@Suite("SnapshotFilename")
struct SnapshotFilenameTests {
    /// The folder every case names into.
    private static let folder = URL(filePath: "/Users/operator/Pictures/Tingra Snapshots", directoryHint: .isDirectory)

    /// 2026-09-10 14:03:12 in the machine's own time zone — the zone the
    /// name is written in — so the expectation holds wherever the tests run.
    private static func moment() throws -> Date {
        try #require(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 9, day: 10, hour: 14, minute: 3, second: 12)))
    }

    @Test("The name says what was saved, then when: Tingra Program 2026-09-10 14.03.12.png")
    func nameShape() throws {
        let url = SnapshotFilename.url(in: Self.folder, subject: "Program", at: try Self.moment()) { _ in false }
        #expect(url.lastPathComponent == "Tingra Program 2026-09-10 14.03.12.png")
        #expect(url.deletingLastPathComponent().standardizedFileURL == Self.folder.standardizedFileURL)
    }

    @Test("The subject is the caller's, in the operator's language; the date keeps one shape")
    func localizedSubjectKeepsTheDateShape() throws {
        let date = try Self.moment()
        #expect(SnapshotFilename.stem(subject: "Programm", at: date) == "Tingra Programm 2026-09-10 14.03.12")
        #expect(SnapshotFilename.stem(subject: "Previo", at: date) == "Tingra Previo 2026-09-10 14.03.12")
    }

    @Test("The timestamp is ASCII digits and separators whatever the locale")
    func timestampIsLocaleIndependent() throws {
        let timestamp = RecordingFilename.timestamp(at: try Self.moment())
        #expect(timestamp == "2026-09-10 14.03.12")
        #expect(timestamp.allSatisfy { $0.isASCII })
    }

    @Test("A slash or a colon in an input's name becomes a dash, and line breaks become spaces")
    func sanitizesPathCharacters() {
        #expect(SnapshotFilename.sanitized("Cam 1/2: Wide") == "Cam 1-2- Wide")
        #expect(SnapshotFilename.sanitized("Title\nCard\tTwo") == "Title Card Two")
        #expect(SnapshotFilename.sanitized("  Padded  ") == "Padded")
    }

    @Test("A very long name is cut at a character boundary within the byte budget")
    func truncatesLongSubjects() {
        let long = String(repeating: "Überschrift ", count: 40)
        let cut = SnapshotFilename.sanitized(long)
        #expect(cut.utf8.count <= SnapshotFilename.maximumSubjectByteCount)
        #expect(long.hasPrefix(cut))
        #expect(!cut.hasSuffix(" "))
        let emoji = String(repeating: "🎬", count: 100)
        #expect(SnapshotFilename.sanitized(emoji).utf8.count <= SnapshotFilename.maximumSubjectByteCount)
        #expect(SnapshotFilename.sanitized(emoji).allSatisfy { $0 == "🎬" })
    }

    @Test("A subject that sanitizes to nothing is left out rather than leaving a double space")
    func emptySubjectIsOmitted() throws {
        #expect(SnapshotFilename.stem(subject: "   ", at: try Self.moment()) == "Tingra 2026-09-10 14.03.12")
    }

    @Test("A name already on disk takes a numeric suffix, never replacing the file there")
    func takenNamesGetASuffix() throws {
        let date = try Self.moment()
        let first = Self.folder.appending(path: "Tingra Program 2026-09-10 14.03.12.png")
        let second = Self.folder.appending(path: "Tingra Program 2026-09-10 14.03.12 2.png")
        let taken: Set<String> = [first.lastPathComponent, second.lastPathComponent]
        let url = SnapshotFilename.url(in: Self.folder, subject: "Program", at: date) {
            taken.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "Tingra Program 2026-09-10 14.03.12 3.png")
    }
}
