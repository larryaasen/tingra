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
///
/// Public since the log window (2026-09-12): a ``LogEntry`` read back from a
/// line carries it, and the window filters on it. The raw value is the word
/// as the line spells it.
public enum LogLevel: String, CaseIterable, Sendable {
    /// `INFO` — the `app`, `event`, and `tap` groups.
    case info = "INFO"
    /// `DEBUG` — the `network` and `trace` groups.
    case debug = "DEBUG"
    /// `ERROR` — the `error` group.
    case error = "ERROR"

    /// The level for an event's group.
    ///
    /// - Parameter group: The event's group.
    public init(group: EventGroup) {
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
    /// The counter file the identifier persists in: `log-session-id` in
    /// Tingra's Application Support directory, beside the project document
    /// and the daemon's socket. Public so the app can list it among the data
    /// it writes and remove it with the rest, naming the same file this
    /// increments rather than a copy of the path.
    public static let counterFileURL = URL.applicationSupportDirectory.appending(path: "Tingra/log-session-id")

    /// This process's log session identifier, read-and-incremented once
    /// per launch.
    public static let currentID: Int = increment(at: counterFileURL)

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

/// One line of a log file, read back: the whole line as written and, where
/// the line is in the human log line format, the parts a reader filters on
/// (ARCHITECTURE.md, "The log window").
///
/// The reading half of ``LogLineFormatter``, kept in the same file so the
/// format and its reader change together. It recovers only what a line
/// carries — the level, the log session ID, the domain, the name, and whether
/// the line is a tap. A line does **not** carry the event's group (the level
/// folds several groups into one) and params are written unquoted
/// (`name=MacBook Pro Microphone`), so neither is read back.
///
/// A line that is not in the format — an older format, a hand edit, a line
/// cut short — is still an entry: ``text`` holds it whole and every parsed
/// part is nil, so a reader shows it rather than dropping it.
public struct LogEntry: Hashable, Sendable {
    /// The line exactly as it is in the file, without its newline.
    public let text: String

    /// The level the line begins with, or nil when the line did not parse.
    public let level: LogLevel?

    /// The log session ID in the line's brackets (`[0042]` is 42), or nil
    /// when the line did not parse (see ``LogSession``).
    public let sessionID: Int?

    /// The domain the event came from (`capture`, `platform`, a plug-in's
    /// identifier), or nil for a tap — whose line drops the domain — and for
    /// a line that did not parse.
    public let domain: String?

    /// The event's name (`device.connected`, or a tap's control name), or nil
    /// when the line did not parse.
    public let name: String?

    /// Whether the line is a tap (`tap=>name - {…}`).
    public let isTap: Bool

    /// Reads a line back.
    ///
    /// - Parameter line: One line of a log file, without its newline.
    public init(line: String) {
        text = line
        guard let parts = Self.parts(of: line) else {
            level = nil
            sessionID = nil
            domain = nil
            name = nil
            isTap = false
            return
        }
        level = parts.level
        sessionID = parts.sessionID
        domain = parts.domain
        name = parts.name
        isTap = parts.isTap
    }

    /// Whether the line was in the human log line format.
    public var isParsed: Bool { level != nil }

    /// What separates a line's header (level, timestamp, zone, session) from
    /// its body — the formatter's `@`, with its spaces.
    private static let bodySeparator = " @ "

    /// How a tap's body begins (``LogLineFormatter``'s `tap=>`).
    private static let tapPrefix = "tap=>"

    /// How a tap's params begin, after its name.
    private static let tapParamsSeparator = " - {"

    /// The parsed parts of a line, before they are stored.
    private struct Parts {
        /// The level.
        let level: LogLevel
        /// The log session ID.
        let sessionID: Int
        /// The domain; nil for a tap.
        let domain: String?
        /// The event's name.
        let name: String
        /// Whether the line is a tap.
        let isTap: Bool
    }

    /// Splits a line into its parts, or nil when it is not in the format.
    ///
    /// The header is exactly five words — level, date, time, zone, and the
    /// bracketed session — since none of them contains a space (the level's
    /// padding is leading, and a zone abbreviation such as `GMT+5:30` has
    /// none). The body is `tap=>name…` for a tap, otherwise `domain name…`.
    ///
    /// - Parameter line: The line.
    /// - Returns: The parts, or nil.
    private static func parts(of line: String) -> Parts? {
        guard let separator = line.range(of: bodySeparator) else { return nil }
        let header = line[..<separator.lowerBound].split(separator: " ")
        guard header.count == 5,
            let level = header.first.flatMap({ LogLevel(rawValue: String($0)) }),
            let session = header.last, session.hasPrefix("["), session.hasSuffix("]"),
            let sessionID = Int(session.dropFirst().dropLast())
        else { return nil }
        let body = line[separator.upperBound...]
        if body.hasPrefix(tapPrefix) {
            let afterPrefix = body.dropFirst(tapPrefix.count)
            let name = afterPrefix.range(of: tapParamsSeparator).map { afterPrefix[..<$0.lowerBound] } ?? afterPrefix
            guard !name.isEmpty else { return nil }
            return Parts(level: level, sessionID: sessionID, domain: nil, name: String(name), isTap: true)
        }
        let words = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard words.count >= 2, !words[0].isEmpty, !words[1].isEmpty else { return nil }
        return Parts(level: level, sessionID: sessionID, domain: String(words[0]), name: String(words[1]), isTap: false)
    }
}
