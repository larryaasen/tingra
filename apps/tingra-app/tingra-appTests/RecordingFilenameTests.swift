//
//  RecordingFilenameTests.swift
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

/// The naming rule that keeps a recording from destroying an earlier one
/// (ARCHITECTURE.md, "Recording in the app").
@Suite("RecordingFilename")
struct RecordingFilenameTests {
    /// The folder every case names into.
    private static let folder = URL(filePath: "/Volumes/Shows", directoryHint: .isDirectory)

    /// 2026-08-06 14:03:12 UTC, built explicitly so the expectation does not
    /// depend on the machine's clock.
    private static func moment(
        year: Int = 2026,
        month: Int = 8,
        day: Int = 6,
        hour: Int = 14,
        minute: Int = 3,
        second: Int = 12
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        return try #require(
            calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute,
                    second: second
                )
            )
        )
    }

    /// The stem those components produce in the machine's own time zone,
    /// which is what the filename is built in.
    private static func expectedStem(for date: Date) -> String {
        RecordingFilename.stem(at: date)
    }

    @Test("The name carries the date and time, zero-padded so a folder sorts chronologically")
    func stemIsDateStamped() throws {
        let stem = RecordingFilename.stem(at: try Self.moment())
        #expect(stem.hasPrefix("Tingra "))
        // Whatever the machine's time zone, the shape is fixed.
        #expect(stem.count == "Tingra 2026-08-06 14.03.12".count)
        #expect(stem.contains("-"))
        #expect(stem.contains("."))
    }

    @Test("Single-digit components are zero-padded, not left ragged")
    func stemZeroPads() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5))
        )
        #expect(RecordingFilename.stem(at: date) == "Tingra 2026-01-02 03.04.05")
    }

    @Test("A colon never reaches the name — the time uses dots, which a path allows")
    func stemAvoidsColons() throws {
        #expect(RecordingFilename.stem(at: try Self.moment()).contains(":") == false)
    }

    @Test("A free name is taken as-is, with the container's extension")
    func freeNameIsUsed() throws {
        let date = try Self.moment()
        let url = RecordingFilename.url(in: Self.folder, container: .mov, at: date, exists: { _ in false })
        #expect(url.lastPathComponent == "\(Self.expectedStem(for: date)).mov")
        #expect(url.deletingLastPathComponent().path() == Self.folder.path())
    }

    @Test("The container picks the extension")
    func containerPicksExtension() throws {
        let url = RecordingFilename.url(in: Self.folder, container: .mp4, at: try Self.moment(), exists: { _ in false })
        #expect(url.pathExtension == "mp4")
    }

    @Test("A name already taken gets a suffix rather than overwriting the earlier take")
    func takenNameGetsSuffix() throws {
        let date = try Self.moment()
        let stem = Self.expectedStem(for: date)
        let taken: Set<String> = ["\(stem).mov"]
        let url = RecordingFilename.url(
            in: Self.folder,
            container: .mov,
            at: date,
            exists: { taken.contains($0.lastPathComponent) }
        )
        #expect(url.lastPathComponent == "\(stem) 2.mov")
    }

    @Test("Two takes in the same second both survive — the suffix keeps counting")
    func twoTakesInOneSecondBothSurvive() throws {
        let date = try Self.moment()
        let stem = Self.expectedStem(for: date)
        let taken: Set<String> = ["\(stem).mov", "\(stem) 2.mov", "\(stem) 3.mov"]
        let url = RecordingFilename.url(
            in: Self.folder,
            container: .mov,
            at: date,
            exists: { taken.contains($0.lastPathComponent) }
        )
        #expect(url.lastPathComponent == "\(stem) 4.mov")
    }

    @Test("Two moments a second apart never produce the same name")
    func distinctMomentsDistinctNames() throws {
        let first = try Self.moment(second: 12)
        let second = try Self.moment(second: 13)
        #expect(RecordingFilename.stem(at: first) != RecordingFilename.stem(at: second))
    }
}
