//
//  ConsoleEventSink.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraHost

/// A development event sink that prints the bus events to standard output, so
/// the event log streams to the terminal when `scripts/run-app.sh` runs the
/// app there.
///
/// **Attached only when `run-app.sh` asks for it** (decided 2026-09-29), by
/// setting `TINGRA_CONSOLE_LOG=1` (``LaunchEnvironment/logsToConsole``). A
/// terminal is the one place it is needed: macOS does not copy the unified
/// log to a terminal (measured 2026-09-29; only `OS_ACTIVITY_DT_MODE` does),
/// so there the host's `OSLogSink` shows nothing. Xcode's console, since
/// Xcode 15, shows the app's unified-log messages itself, so attaching this
/// sink there printed every event twice; the OSLog copy is the better one in
/// Xcode, filterable by subsystem and category, with the time in its
/// metadata. A scheme that wants the house format in Xcode can set the
/// variable too. This sink was first added, 2026-07-06, on the premise that
/// the unified log never reaches Xcode's console, which Xcode 15 ended.
///
/// It is a dev convenience, not a replacement for the OSLog system of record
/// the shipping product relies on, nor for the host's `FileSink` writing the
/// log file an operator shares; ``EngineModel/start(launch:)`` attaches those
/// two always (EVENTS.md, "Sinks"). Until 2026-09-08 it was the only sink the
/// app attached, so a Tingra.app launched from the Finder recorded nothing
/// anywhere.
///
/// It renders lines with the shared ``LogLineFormatter`` (the same host format
/// the CLI's console and file sinks use) and filters to `app`/`error`/`event`/
/// `tap` so `network`/`trace` chatter stays quiet. This differs from the CLI's
/// console sink, which additionally silences `tap` by default — that policy
/// exists because the CLI can turn it back on with `--verbose`; the app has no
/// such flag, and `tap` is exactly what a developer watching this console
/// wants to see now that the app has buttons to click (EVENTS.md, "The `tap`
/// convention"). Params are printed in the clear, which is safe here because
/// the app emits no secrets — secrets must never become event params in the
/// first place (EVENTS.md, Redaction); this sink must not be shipped
/// as-is for a build that carries stream keys.
struct ConsoleEventSink: EventSink {
    /// This sink's default filter: every group but `network`/`trace` (the two
    /// still `debug`-level chatter per EVENTS.md's table). Unlike the CLI's
    /// console sink, `tap` is included by default — see the type's docs.
    static let defaultGroups: Set<EventGroup> = [.app, .error, .event, .tap]

    /// The groups this sink prints; everything else is dropped.
    private let groups: Set<EventGroup>

    /// Renders each event as a line — the one shared host log format.
    private let formatter: LogLineFormatter

    /// Where rendered lines go. Defaults to `print` (stdout, the Xcode
    /// console); tests inject a collector.
    private let emit: @Sendable (String) -> Void

    /// Creates the sink.
    ///
    /// - Parameters:
    ///   - groups: The groups to print (default: the EVENTS.md defaults).
    ///   - formatter: The line formatter (default: the shared host format).
    ///   - emit: Where lines go (default: `print` to stdout).
    init(
        groups: Set<EventGroup> = ConsoleEventSink.defaultGroups,
        formatter: LogLineFormatter = LogLineFormatter(),
        emit: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.groups = groups
        self.formatter = formatter
        self.emit = emit
    }

    func receive(_ event: EventBusEvent) async {
        guard groups.contains(event.group) else { return }
        emit(formatter.line(for: event))
    }
}
