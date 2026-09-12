//
//  LogFileTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus

@testable import TingraHost

/// Builds one real bus event by sending it through a fresh bus — the shape
/// the capture plug-in emits, without a public memberwise init.
private func deviceEvent(name: String = "device.connected", kind: String = "camera") async -> EventBusEvent? {
    let bus = EventBus()
    let events = bus.events()
    bus.send(
        .event,
        domain: .capture,
        name: name,
        params: ["id": .string("0x1"), "name": .string("Some Device"), "kind": .string(kind)]
    )
    bus.shutdown()
    for await event in events {
        return event
    }
    return nil
}

/// A fresh, empty folder for one test, removed when the test ends.
private struct TemporaryFolder {
    /// The folder.
    let url = FileManager.default.temporaryDirectory.appending(
        path: "tingra-logfile-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )

    /// Creates the folder on disk.
    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A file inside the folder.
    func file(_ name: String) -> URL { url.appending(path: name) }

    /// Removes the folder and everything in it.
    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite("FileSink")
struct FileSinkTests {
    @Test("events append to the log file in the exact console human line format")
    func appendsHumanLines() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let path = folder.file("events.log").path(percentEncoded: false)
        let formatter = LogLineFormatter(sessionID: 7)
        let sink = FileSink(path: path, formatter: formatter)
        let event = try #require(await deviceEvent())

        await sink.receive(event)
        await sink.receive(event)

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("device.connected") })
        // One format for both sinks: the file line is the formatter's line,
        // byte for byte.
        #expect(lines.first == Substring(formatter.line(for: event)))
    }

    @Test("the first line creates a missing parent folder along with the file")
    func createsParentFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appending(path: "Logs/Tingra/Tingra.log")
        let sink = FileSink(url: url)
        let event = try #require(await deviceEvent())

        await sink.receive(event)

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.split(separator: "\n").count == 1)
        #expect(contents.contains("device.connected"))
    }

    @Test("an existing file is appended to, never replaced")
    func appendsToExisting() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.file("events.log")
        try "earlier line\n".write(to: url, atomically: true, encoding: .utf8)
        let sink = FileSink(url: url)
        let event = try #require(await deviceEvent())

        await sink.receive(event)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first == "earlier line")
        #expect(lines.last?.contains("device.connected") == true)
    }

    @Test("writing continues after the file is cleared in place, starting at offset zero")
    func writesAfterClear() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.file("events.log")
        let sink = FileSink(url: url)
        let logFile = LogFile(url: url)
        let event = try #require(await deviceEvent())

        await sink.receive(event)
        await sink.receive(event)
        try logFile.clear()
        await sink.receive(event)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
    }
}

@Suite("LogFile")
struct LogFileTests {
    @Test("the default location is Tingra.log in the user's Library/Logs/Tingra folder")
    func defaultLocation() {
        let logFile = LogFile()
        #expect(logFile.url.path(percentEncoded: false).hasSuffix("/Library/Logs/Tingra/Tingra.log"))
        #expect(logFile.folderURL.path(percentEncoded: false).hasSuffix("/Library/Logs/Tingra/"))
    }

    @Test("a missing file has no size and does not exist")
    func missingFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logFile = LogFile(url: folder.file("Tingra.log"))
        #expect(!logFile.exists)
        #expect(logFile.byteCount == nil)
    }

    @Test("the size is the bytes on disk")
    func byteCount() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logFile = LogFile(url: folder.file("Tingra.log"))
        try Data("twelve bytes".utf8).write(to: logFile.url)
        #expect(logFile.exists)
        #expect(logFile.byteCount == 12)
    }

    @Test("clearing a missing file reports zero bytes and creates nothing")
    func clearMissing() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logFile = LogFile(url: folder.file("Tingra.log"))
        #expect(try logFile.clear() == 0)
        #expect(!logFile.exists)
    }

    @Test("clearing truncates in place and reports the size the file had")
    func clearTruncates() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logFile = LogFile(url: folder.file("Tingra.log"))
        try Data("twelve bytes".utf8).write(to: logFile.url)
        #expect(try logFile.clear() == 12)
        #expect(logFile.exists)
        #expect(logFile.byteCount == 0)
    }

    @Test("a snapshot copies the contents to a dated text file and leaves the log untouched")
    func snapshotCopies() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logFile = LogFile(url: folder.file("Tingra.log"))
        try "line one\nline two\n".write(to: logFile.url, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_788_000_000)

        let snapshot = try logFile.snapshot(in: folder.url, at: date)

        #expect(snapshot.deletingLastPathComponent() == folder.url)
        #expect(snapshot.lastPathComponent == LogFile.snapshotName(for: date))
        #expect(try String(contentsOf: snapshot, encoding: .utf8) == "line one\nline two\n")
        #expect(logFile.byteCount == 18)
    }

    @Test("a second snapshot the same day replaces the first rather than throwing")
    func snapshotReplaces() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logFile = LogFile(url: folder.file("Tingra.log"))
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        try "first\n".write(to: logFile.url, atomically: true, encoding: .utf8)
        let first = try logFile.snapshot(in: folder.url, at: date)
        try "first\nsecond\n".write(to: logFile.url, atomically: true, encoding: .utf8)

        let second = try logFile.snapshot(in: folder.url, at: date)

        #expect(first == second)
        #expect(try String(contentsOf: second, encoding: .utf8) == "first\nsecond\n")
    }

    @Test("a snapshot of a missing or empty log throws empty")
    func snapshotEmpty() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logFile = LogFile(url: folder.file("Tingra.log"))
        #expect(throws: LogFileError.empty(logFile.url)) {
            try logFile.snapshot(in: folder.url)
        }
        try Data().write(to: logFile.url)
        #expect(throws: LogFileError.empty(logFile.url)) {
            try logFile.snapshot(in: folder.url)
        }
    }

    @Test("the snapshot name is a verbatim year-month-day text file")
    func snapshotName() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        // 2026-09-08 00:00:00 UTC.
        let date = Date(timeIntervalSince1970: 1_788_825_600)
        #expect(LogFile.snapshotName(for: date, timeZone: utc) == "Tingra Log 2026-09-08.txt")
    }

    @Test("the error names the file and says what to do")
    func errorDescription() {
        let error = LogFileError.empty(URL(filePath: "/tmp/Tingra.log"))
        #expect(error.description.contains("/tmp/Tingra.log"))
        #expect(error.description.contains("nothing to snapshot"))
    }

    @Test("errors compare equal for the same file and unequal for different files")
    func errorEquality() {
        let a = LogFileError.empty(URL(filePath: "/a/Tingra.log"))
        #expect(a == LogFileError.empty(URL(filePath: "/a/Tingra.log")))
        #expect(a != LogFileError.empty(URL(filePath: "/b/Tingra.log")))
    }
}

@Suite("LogFile lines")
struct LogFileLinesTests {
    /// Writes `text` to a log file in a fresh folder and returns the file.
    private func logFile(_ text: String, in folder: TemporaryFolder) throws -> LogFile {
        let logFile = LogFile(url: folder.file("Tingra.log"))
        try Data(text.utf8).write(to: logFile.url)
        return logFile
    }

    @Test("a missing file reads as no lines with nothing earlier")
    func missingFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let chunk = try LogFile(url: folder.file("Tingra.log")).lines()
        #expect(chunk == LogFileChunk(lines: [], startOffset: 0))
        #expect(!chunk.hasEarlierLines)
    }

    @Test("a file smaller than the read comes back whole, without the final newline's empty line")
    func smallerThanRead() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let chunk = try logFile("alpha\nbravo\n", in: folder).lines(maxByteCount: 100)
        #expect(chunk == LogFileChunk(lines: ["alpha", "bravo"], startOffset: 0))
    }

    @Test("a read starting partway into a line drops that line's tail and starts at the next line")
    func cutsAtLineBoundary() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // alpha\n is bytes 0–5, bravo\n 6–11, charlie\n 12–19.
        let file = try logFile("alpha\nbravo\ncharlie\n", in: folder)

        #expect(try file.lines(maxByteCount: 10) == LogFileChunk(lines: ["charlie"], startOffset: 12))
        // A read starting exactly at a line's first byte keeps that line.
        #expect(try file.lines(maxByteCount: 8) == LogFileChunk(lines: ["charlie"], startOffset: 12))
        #expect(try file.lines(maxByteCount: 9) == LogFileChunk(lines: ["charlie"], startOffset: 12))
        #expect(
            try file.lines(before: 12, maxByteCount: 12) == LogFileChunk(lines: ["alpha", "bravo"], startOffset: 0))
    }

    @Test("a cut inside a multibyte character never splits it")
    func multibyteStraddle() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // héllo\n is bytes 0–6 (é is two bytes, 1–2); wörld\n is 7–13. A
        // 12-byte read starts at 2, inside the é.
        let file = try logFile("héllo\nwörld\n", in: folder)

        let last = try file.lines(maxByteCount: 12)
        #expect(last == LogFileChunk(lines: ["wörld"], startOffset: 7))
        #expect(try file.lines(before: last.startOffset, maxByteCount: 12).lines == ["héllo"])
    }

    @Test("consecutive reads back to the start meet with no line lost or doubled")
    func consecutiveReadsMeet() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let written = (1...200).map { "line \($0) " + String(repeating: "x", count: $0 % 17) }
        let file = try logFile(written.joined(separator: "\n") + "\n", in: folder)

        var chunks: [LogFileChunk] = [try file.lines(maxByteCount: 64)]
        while let earliest = chunks.last, earliest.hasEarlierLines {
            chunks.append(try file.lines(before: earliest.startOffset, maxByteCount: 64))
        }

        #expect(chunks.reversed().flatMap(\.lines) == written)
    }

    @Test("an offset past the end, as after a clear, reads to the file's end")
    func offsetPastEnd() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try logFile("alpha\nbravo\n", in: folder)
        try file.clear()
        try Data("cleared\n".utf8).write(to: file.url)

        #expect(try file.lines(before: 500) == LogFileChunk(lines: ["cleared"], startOffset: 0))
    }

    @Test("a line longer than the read yields no lines but still moves back")
    func lineLongerThanRead() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try logFile("short\n" + String(repeating: "y", count: 40) + "\n", in: folder)

        let chunk = try file.lines(maxByteCount: 10)
        #expect(chunk.lines.isEmpty)
        #expect(chunk.startOffset < 46)
        #expect(chunk.hasEarlierLines)
    }

    @Test("a folder where the file should be throws rather than reading as empty")
    func unreadableThrows() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.file("Tingra.log")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try LogFile(url: url).lines()
        }
    }

    @Test("chunks with the same lines and offset are equal, and differ when either differs")
    func chunkEquality() {
        let chunk = LogFileChunk(lines: ["a"], startOffset: 4)
        #expect(chunk == LogFileChunk(lines: ["a"], startOffset: 4))
        #expect(chunk != LogFileChunk(lines: ["a"], startOffset: 0))
        #expect(chunk != LogFileChunk(lines: ["b"], startOffset: 4))
    }
}
