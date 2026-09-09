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
