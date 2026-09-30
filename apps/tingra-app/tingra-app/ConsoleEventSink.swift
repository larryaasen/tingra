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

/// A development event sink that prints the bus events to standard output in
/// the log file's own format, so a developer running the app from Xcode or
/// from a terminal reads the same lines the log file holds.
///
/// **Attached only when the launch asks for it** (decided 2026-09-29), with
/// `TINGRA_CONSOLE_LOG=1` (``LaunchEnvironment/logsToConsole``), which the
/// `tingra-app` scheme's Run action and `scripts/run-app.sh` both set. When it
/// is attached, the host's `OSLogSink` is not: since Xcode 15, Xcode's
/// console shows the app's unified-log messages itself, so the two sinks
/// printed every event twice there, the OSLog copy without the level and time
/// the log file's lines carry. A terminal shows no unified log at all
/// (measured 2026-09-29: macOS copies `os_log` to a terminal only under
/// `OS_ACTIVITY_DT_MODE`). A launch without the variable — the Finder, the
/// shipping app — keeps OSLog as its system of record, and every launch keeps
/// the host's `FileSink` writing the log file an operator shares
/// (``EngineModel/start(launch:)``; EVENTS.md, "Sinks"). The cost of a
/// developer run is only that its events are not in Console.app; the log file
/// has every one. Until 2026-09-08 this was the only sink the app attached,
/// so a Tingra.app launched from the Finder recorded nothing anywhere.
///
/// It renders lines with the shared ``LogLineFormatter`` (the same host format
/// the CLI's console and file sinks use) and prints every group, as the log
/// file does (2026-09-29): it is the only live view of a developer run, so a
/// `trace` or `network` line left out here would be seen nowhere but the
/// file. That includes `tap`, which the CLI's console sink silences by
/// default and turns back on with `--verbose`; the app has no such flag, and
/// `tap` is exactly what a developer watching this console wants to see
/// (EVENTS.md, "The `tap` convention"). Params are printed in the clear, which is safe here because
/// the app emits no secrets — secrets must never become event params in the
/// first place (EVENTS.md, Redaction); this sink must not be shipped
/// as-is for a build that carries stream keys.
struct ConsoleEventSink: EventSink {
    /// This sink's default filter: every group, as the log file prints them —
    /// see the type's docs.
    static let defaultGroups = Set(EventGroup.allCases)

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
