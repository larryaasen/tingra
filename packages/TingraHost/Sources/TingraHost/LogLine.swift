//
//  LogLine.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus

/// The level a log line begins with, derived from the event's group per
/// EVENTS.md's default sink levels: `error` → ERROR, `network`/`trace` →
/// DEBUG, `app`/`event`/`tap` → INFO.
enum LogLevel: String, Sendable {
    case info = "INFO"
    case debug = "DEBUG"
    case error = "ERROR"

    /// The level for an event's group.
    init(group: EventGroup) {
        switch group {
        case .error: self = .error
        case .network, .trace: self = .debug
        case .app, .event, .tap: self = .info
        }
    }

    /// The fixed-width (five character) form, right-justified with leading
    /// spaces (` INFO`, `DEBUG`, `ERROR`), so every line's timestamp starts
    /// in the same column.
    var padded: String {
        String(repeating: " ", count: max(0, 5 - rawValue.count)) + rawValue
    }
}

/// The one human log line format, shared across every sink that renders events
/// as text — the CLI's console (human mode) and file sinks, and the app's
/// console sink (EVENTS.md, "The human log line format"). It lives in the host
/// so any front end can reuse the identical format:
///
/// ```
/// LEVEL MM-DD-YYYY HH:MM:SS.mmm TZ [SSSS] @ domain name key=value …
///  INFO MM-DD-YYYY HH:MM:SS.mmm TZ [SSSS] @ tap=>name - {key: value, …}
/// ```
///
/// — a fixed-width, right-justified level, a verbatim local timestamp with
/// time zone, the four-digit log session ID in brackets, `@`, then the
/// body: for most groups the event's domain, name, and sorted `key=value`
/// params; a `tap` event renders distinctively instead (see
/// ``body(for:)``), mirroring Larry's Dart `EventBusBasics` tap-line style.
public struct LogLineFormatter: Sendable {
    /// The log session identifier stamped into every line (see
    /// ``LogSession``).
    private let sessionID: Int

    /// The time zone timestamps render in.
    private let timeZone: TimeZone

    /// The verbatim timestamp style — `Date.FormatStyle`, never a legacy
    /// formatter (CLAUDE.md), and verbatim so log output is
    /// locale-independent.
    private let timestampStyle: Date.VerbatimFormatStyle

    /// Creates a formatter. Defaults stamp the process's log session ID
    /// and the local time zone; tests inject fixed values.
    ///
    /// - Parameters:
    ///   - sessionID: The four-digit log session id to stamp (default: this
    ///     process's ``LogSession/currentID``).
    ///   - timeZone: The time zone timestamps render in (default: the current
    ///     zone).
    public init(sessionID: Int = LogSession.currentID, timeZone: TimeZone = .current) {
        self.sessionID = sessionID
        self.timeZone = timeZone
        self.timestampStyle = Date.VerbatimFormatStyle(
            format: """
                \(month: .twoDigits)-\(day: .twoDigits)-\(year: .padded(4)) \
                \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\
                \(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))
                """,
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    /// One event as one log line.
    ///
    /// - Parameter event: The bus event to render.
    /// - Returns: The formatted line (no trailing newline).
    public func line(for event: EventBusEvent) -> String {
        let level = LogLevel(group: event.group).padded
        let timestamp = event.date.formatted(timestampStyle)
        let zone = timeZone.abbreviation(for: event.date) ?? "GMT"
        let session = (sessionID % 10_000)
            .formatted(.number.precision(.integerLength(4...)).grouping(.never))
        return "\(level) \(timestamp) \(zone) [\(session)] @ \(Self.body(for: event))"
    }

    /// The line body after `@`: `domain name key=value …` for every group
    /// except `tap`, which instead renders `tap=>name - {key: value, …}` —
    /// the domain is dropped from view (a tap's params carry whatever
    /// attribution matters, e.g. `screen`), matching the arrow-and-map style
    /// of Larry's Dart `EventBusBasics` tap line.
    private static func body(for event: EventBusEvent) -> String {
        switch event.group {
        case .tap:
            let params =
                event.params.map { params in
                    " - {" + params.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                        + "}"
                } ?? ""
            return "tap=>\(event.name)\(params)"
        default:
            let params =
                event.params.map { params in
                    " " + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                } ?? ""
            return "\(event.domain.rawValue) \(event.name)\(params)"
        }
    }
}

/// The log session: a four-digit identifier that increments exactly once
/// per cold start (for `tingra-cli`, every process launch), persisted in
/// Application Support. A change from `[0042]` to `[0043]` in a log file
/// marks a new process, and grouping lines by the ID separates the
/// sessions interleaved in one file — a reliable cold-start anchor.
///
/// Distinct from the engine **session** in GLOSSARY.md (the live running
/// state of the engine); this is purely a log anchor. When the `serve`
/// daemon arrives (roadmap step 4), its warm starts will keep the same ID.
public enum LogSession {
    /// This process's log session identifier, read-and-incremented once
    /// per launch.
    public static let currentID: Int = increment(
        at: URL.applicationSupportDirectory.appending(path: "Tingra/log-session-id")
    )

    /// Reads the last identifier from `url`, increments it (wrapping to
    /// four digits), persists, and returns it. Best effort by design: an
    /// unreadable or unwritable counter file falls back to session 1
    /// rather than failing the command — logging must never take down the
    /// process.
    ///
    /// - Parameter url: The counter file to read, increment, and rewrite.
    /// - Returns: The new session identifier.
    public static func increment(at url: URL) -> Int {
        let previous =
            (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let next = (previous + 1) % 10_000
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? String(next).write(to: url, atomically: true, encoding: .utf8)
        return next
    }
}
