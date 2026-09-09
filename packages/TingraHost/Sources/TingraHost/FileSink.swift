//
//  FileSink.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus

/// The file sink: the same formatted lines as the CLI console's human mode
/// (one ``LogLineFormatter`` format for both), appended to a file — every
/// group, no filter (EVENTS.md, "Sinks").
///
/// `tingra-cli` attaches one when `--log-file` is passed; the app attaches
/// one always, over ``LogFile/defaultURL``. It lives in the host rather than
/// in either front end for the reason ``LogLineFormatter`` does: a second
/// front end needing the same sink (moved here from `tingra-cli`
/// 2026-09-08).
///
/// The file is created on the first event if it does not exist — its parent
/// folder too, so the app's `~/Library/Logs/Tingra/` need not be made ahead
/// of time — and appended to from then on. Each line opens a fresh handle and
/// seeks to the end, which is what lets ``LogFile/clear()`` truncate the file
/// in place underneath a running sink: the next line lands at offset zero of
/// the emptied file, with no window between a delete and a recreate.
///
/// An output problem must never take down the process, so write failures are
/// swallowed — the OSLog sink remains the system of record.
public struct FileSink: EventSink {
    /// The file the sink appends to.
    private let url: URL

    /// Renders lines in the shared human log format.
    private let formatter: LogLineFormatter

    /// Creates a sink appending to the file at a path — the CLI's
    /// `--log-file` form.
    ///
    /// - Parameters:
    ///   - path: The file to append to; created on the first event if it
    ///     does not exist.
    ///   - formatter: The line formatter (default: the shared host format).
    public init(path: String, formatter: LogLineFormatter = LogLineFormatter()) {
        self.init(url: URL(filePath: path), formatter: formatter)
    }

    /// Creates a sink appending to a file.
    ///
    /// - Parameters:
    ///   - url: The file to append to; created on the first event, with its
    ///     parent folder, if it does not exist.
    ///   - formatter: The line formatter (default: the shared host format).
    public init(url: URL, formatter: LogLineFormatter = LogLineFormatter()) {
        self.url = url
        self.formatter = formatter
    }

    /// Appends one formatted line.
    ///
    /// - Parameter event: The event to write.
    public func receive(_ event: EventBusEvent) async {
        let line = Data((formatter.line(for: event) + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            // No file yet: make sure its folder exists, then create it with
            // this first line.
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? line.write(to: url)
        }
    }
}
