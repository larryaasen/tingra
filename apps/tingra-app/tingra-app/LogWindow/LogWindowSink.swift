//
//  LogWindowSink.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraHost

/// The log window's sink: each event as the log line the file sink writes for
/// it, handed to the window while it is open and not paused (EVENTS.md, "Log
/// window sink").
///
/// It keeps nothing. The window reads its history from the log file, and this
/// sink only carries the lines sent after it attached — formatted by the same
/// `LogLineFormatter` the file sink uses, so a live line is byte-identical to
/// the file's and the window can tell where the two overlap
/// (``LogWindowModel``). Every group, no filter: the window filters what it
/// shows, and the file it mirrors holds every group. Detached by cancelling the
/// task `EventBus.attach` returned.
struct LogWindowSink: EventSink {
    /// Formats each event exactly as the file sink does.
    private let formatter: LogLineFormatter

    /// Hands a formatted line to the window.
    private let deliver: @Sendable (String) async -> Void

    /// Creates the sink.
    ///
    /// - Parameters:
    ///   - formatter: The formatter — the file sink's, so lines match the
    ///     file's byte for byte.
    ///   - deliver: Receives each line, in emission order.
    init(formatter: LogLineFormatter, deliver: @escaping @Sendable (String) async -> Void) {
        self.formatter = formatter
        self.deliver = deliver
    }

    /// Formats one event and delivers the line.
    ///
    /// - Parameter event: The bus event.
    func receive(_ event: EventBusEvent) async {
        await deliver(formatter.line(for: event))
    }
}
