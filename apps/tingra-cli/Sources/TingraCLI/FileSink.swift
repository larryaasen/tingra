//
//  FileSink.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus

/// The file sink, attached by `--log-file`: the same formatted lines as
/// the console's human mode (one `LogLineFormatter` format for both),
/// appended to a file (EVENTS.md, "Sinks").
struct FileSink: EventSink {
    /// The file the sink appends to.
    private let path: String

    /// Renders lines in the shared human log format.
    private let formatter: LogLineFormatter

    /// Creates a sink appending to the given path. The file is created on
    /// the first event if it does not exist.
    init(path: String, formatter: LogLineFormatter = LogLineFormatter()) {
        self.path = path
        self.formatter = formatter
    }

    /// Appends one formatted line. An output problem must never take down
    /// the process, so write failures are swallowed — the OSLog sink
    /// remains the system of record.
    func receive(_ event: EventBusEvent) async {
        let line = formatter.line(for: event) + "\n"
        let url = URL(filePath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
