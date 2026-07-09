//
//  ConsoleEventSink.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraHost

/// A development event sink that prints the bus events to standard output, so
/// the event log is visible in Xcode's console when the app runs under the
/// debugger.
///
/// The engine's always-on ``OSLogSink`` routes events into the unified logging
/// system (Console.app, `log stream`), which does **not** surface in Xcode's
/// debug console — so while developing `apps/tingra` we attach this sink
/// instead, sending one line per event to stdout where the app is actually
/// run. It is a dev convenience, not a replacement for the OSLog
/// system-of-record the shipping product relies on (EVENTS.md, "Sinks").
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
