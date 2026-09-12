//
//  LogFile.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The one log file the app's ``FileSink`` appends to, and the three things
/// an operator does with it from the Logging settings pane — read its size,
/// share a dated snapshot of it, and clear it (EVENTS.md, "Sinks";
/// ARCHITECTURE.md, "The log file and the Logging settings pane").
///
/// A locator over one URL rather than the sink itself: the sink writes, this
/// answers questions about what was written. Every place that names the
/// app's log — the sink, the Logging pane, the Data pane's inventory, the
/// Help menu — goes through ``defaultURL``, so none of them can name a
/// different file. The URL is injectable, so tests run the real snapshot and
/// the real clear against a temporary directory, never the operator's log.
///
/// It emits nothing: the `log.cleared` event the clear is recorded as is the
/// app's to send, since the app is what knows the clear was the operator's.
public struct LogFile: Sendable {
    /// Where the app's log lives: `~/Library/Logs/Tingra/Tingra.log` — the
    /// folder Mac apps put their logs in and the one Console.app's Log
    /// Reports lists. Not Documents (an iOS sandbox habit) and not
    /// Application Support, which holds the show.
    public static let defaultURL = URL.libraryDirectory.appending(path: "Logs/Tingra/Tingra.log")

    /// The file.
    public let url: URL

    /// Creates a locator over a file.
    ///
    /// - Parameter url: The log file (default: ``defaultURL``).
    public init(url: URL = LogFile.defaultURL) {
        self.url = url
    }

    /// The folder the file is in — what the Logging pane opens in the Finder.
    public var folderURL: URL { url.deletingLastPathComponent() }

    /// Whether the file exists. A sink creates it on its first line, so a
    /// fresh install has none until the first event lands.
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// The file's size in bytes, or nil when there is no file yet.
    ///
    /// Read through `FileManager` rather than `URL.resourceValues`, which
    /// caches what it read for the rest of the run-loop pass — a size taken
    /// just before a clear would otherwise be reported again right after it.
    public var byteCount: Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let size = attributes?[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// The name a snapshot taken at a moment gets: `Tingra Log 2026-09-08.txt`.
    ///
    /// A verbatim year-month-day rather than a localized date, so the name
    /// sorts and reads the same on every Mac; `.txt` rather than `.log`, so
    /// a double-click opens it in TextEdit and Mail and Messages treat it as
    /// text rather than an attachment to be careful of.
    ///
    /// - Parameters:
    ///   - date: The moment the snapshot is taken.
    ///   - timeZone: The zone the day is read in (default: the current one;
    ///     tests fix it).
    /// - Returns: The file name.
    public static func snapshotName(for date: Date, timeZone: TimeZone = .current) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)",
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
        return "Tingra Log \(date.formatted(style)).txt"
    }

    /// Copies the log's current contents to a dated file in a folder and
    /// returns that file — what Share Log File hands the share picker: a
    /// snapshot, rather than the live file a sink is still appending to. A
    /// second snapshot the same day replaces the first.
    ///
    /// - Parameters:
    ///   - directory: The folder to write the snapshot in (default: the
    ///     temporary directory).
    ///   - date: The moment named in the file (default: now).
    /// - Returns: The snapshot.
    /// - Throws: ``LogFileError/empty(_:)`` when there is no log file or
    ///   nothing in it; the file-system error when the copy cannot be written.
    public func snapshot(in directory: URL = FileManager.default.temporaryDirectory, at date: Date = .now) throws -> URL
    {
        guard exists else { throw LogFileError.empty(url) }
        let contents = try Data(contentsOf: url)
        guard !contents.isEmpty else { throw LogFileError.empty(url) }
        let snapshotURL = directory.appending(path: Self.snapshotName(for: date))
        try contents.write(to: snapshotURL, options: .atomic)
        return snapshotURL
    }

    /// Empties the file in place and returns how many bytes it held.
    ///
    /// Truncates rather than deletes: ``FileSink`` opens a fresh handle per
    /// line and seeks to the end, so an emptied file keeps working with no
    /// window between a delete and the next line recreating it. A missing
    /// file is already the state being asked for, and reports zero bytes.
    ///
    /// - Returns: The size the file had before it was emptied.
    /// - Throws: The file-system error when the file exists and cannot be
    ///   truncated.
    @discardableResult
    public func clear() throws -> Int64 {
        guard exists else { return 0 }
        let previous = byteCount ?? 0
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        return previous
    }

    /// How much of the file one read takes: 2 MB, roughly ten to fifteen
    /// thousand lines — what the log window opens with, and what each Load
    /// Earlier Lines adds (ARCHITECTURE.md, "The log window"). The file has no
    /// size cap, so it is never read whole.
    public static let chunkByteCount = 2 << 20

    /// Reads the whole lines in the bytes that end at an offset — the file's
    /// end by default — going back at most `maxByteCount` bytes.
    ///
    /// A read that starts partway into the file drops the bytes before its
    /// first newline, since they are the tail of a line that began earlier;
    /// the returned ``LogFileChunk/startOffset`` is where the first whole line
    /// begins, so the next read, ending there, returns that line whole and
    /// consecutive reads meet with no line lost or doubled. The cut is made at
    /// a newline byte, which never occurs inside a multibyte UTF-8 character,
    /// so it cannot split one. The one exception is a single line longer than
    /// `maxByteCount`: a read that holds no newline but its last returns no
    /// lines and starts at its own first byte, so reading keeps moving back.
    ///
    /// A missing file reads as no lines. An offset past the file's end — the
    /// file was cleared since it was taken — reads to the end.
    ///
    /// - Parameters:
    ///   - offset: The byte the read ends before (default: the file's end).
    ///   - maxByteCount: The most bytes to read (default: ``chunkByteCount``).
    /// - Returns: The lines, oldest first, and the offset the first begins at.
    /// - Throws: The file-system error when the file exists and cannot be read.
    public func lines(before offset: UInt64? = nil, maxByteCount: Int = LogFile.chunkByteCount) throws
        -> LogFileChunk
    {
        guard maxByteCount > 0, let size = byteCount.map({ UInt64(max($0, 0)) }) else {
            return LogFileChunk(lines: [], startOffset: 0)
        }
        let end = min(offset ?? size, size)
        let start = end > UInt64(maxByteCount) ? end - UInt64(maxByteCount) : 0
        guard end > start else { return LogFileChunk(lines: [], startOffset: start) }

        // Starting one byte early says whether `start` is itself the first
        // byte of a line: that byte is then the newline the cut is made at.
        let readStart = start > 0 ? start - 1 : 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: readStart)
        let data = try handle.read(upToCount: Int(end - readStart)) ?? Data()

        var body = data[...]
        var firstLineOffset = readStart
        if start > 0 {
            guard let newline = data.firstIndex(of: Self.newline), newline + 1 < data.endIndex else {
                return LogFileChunk(lines: [], startOffset: start)
            }
            body = data[(newline + 1)...]
            firstLineOffset = readStart + UInt64(newline + 1 - data.startIndex)
        }
        var lines = body.split(separator: Self.newline, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // The file's last newline ends a line; it does not begin an empty one.
        if lines.last == "" { lines.removeLast() }
        return LogFileChunk(lines: lines, startOffset: firstLineOffset)
    }

    /// The byte that ends every line.
    private static let newline = UInt8(ascii: "\n")
}

/// The lines one ``LogFile/lines(before:maxByteCount:)`` read returned, and
/// where in the file they begin — which is where the next read, for the lines
/// before these, ends.
public struct LogFileChunk: Equatable, Sendable {
    /// The whole lines read, oldest first, without their newlines.
    public let lines: [String]

    /// The byte offset in the file where the first line begins.
    public let startOffset: UInt64

    /// Creates a chunk.
    ///
    /// - Parameters:
    ///   - lines: The lines, oldest first.
    ///   - startOffset: Where the first line begins.
    public init(lines: [String], startOffset: UInt64) {
        self.lines = lines
        self.startOffset = startOffset
    }

    /// Whether the file holds lines before these.
    public var hasEarlierLines: Bool { startOffset > 0 }
}

/// What ``LogFile`` can refuse to do, with the cause and the fix in the
/// message (CLAUDE.md, "Never crash the process").
public enum LogFileError: Error, Equatable, CustomStringConvertible {
    /// A snapshot was asked of a log that does not exist or holds nothing —
    /// there is nothing to share yet.
    case empty(URL)

    public var description: String {
        switch self {
        case .empty(let url):
            "The log file at \(url.path(percentEncoded: false)) is empty or does not exist yet, so there is "
                + "nothing to snapshot. It is created on the first event and appended to from then on."
        }
    }
}
