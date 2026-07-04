//
//  ConsoleSink.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus

/// The console sink, owned by `tingra-cli` (see EVENTS.md, "Sinks").
///
/// Human mode prints formatted lines to standard error, keeping standard
/// output clean for command results (the devices listing, and later the
/// stream status stream). JSON mode serializes the same events as newline
/// delimited JSON on standard output — the `--json` status events in CLI.md
/// are bus events, one source of truth for humans, scripts, and agents.
struct ConsoleSink: EventSink {
    /// How the sink renders events.
    enum Mode: Sendable {
        /// Formatted human readable lines, written to standard error.
        case human

        /// Newline delimited JSON records, written to standard output.
        case json
    }

    /// The EVENTS.md default filter — info level and up. `network`, `tap`,
    /// and `trace` stay silent; `--verbose`/`--quiet` arrive as filters on
    /// this sink with the stream command.
    static let defaultGroups: Set<EventGroup> = [.app, .error, .event]

    /// One `--json` NDJSON record: the stable field set from EVENTS.md
    /// (`ts`, `group`, `domain`, `name`, `params`). JSON keys are a
    /// scripting contract — mapped explicitly, never renamed.
    struct JSONRecord: Codable, Equatable {
        /// When the event was emitted (ISO 8601 in output).
        let ts: Date

        /// The event's routing axis.
        let group: EventGroup

        /// The event's attribution axis.
        let domain: EventDomain

        /// The event's dotted lowercase identifier.
        let name: String

        /// The event's structured payload, absent when the event has none.
        let params: [String: EventValue]?

        /// The stable JSON keys.
        private enum CodingKeys: String, CodingKey {
            case ts
            case group
            case domain
            case name
            case params
        }

        /// Creates a record from a bus event.
        init(_ event: EventBusEvent) {
            self.ts = event.date
            self.group = event.group
            self.domain = event.domain
            self.name = event.name
            self.params = event.params
        }
    }

    /// The rendering mode, per the command's `--json` flag.
    private let mode: Mode

    /// The groups this sink prints; everything else is filtered out.
    private let groups: Set<EventGroup>

    /// Where rendered lines go. Defaults per mode (standard error for
    /// human lines, standard output for NDJSON); tests inject a collector.
    private let emit: @Sendable (String) -> Void

    /// The NDJSON encoder: ISO 8601 timestamps, sorted keys so the same
    /// event always serializes to the same line.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Creates a sink for the given mode and group filter, writing to the
    /// mode's default stream unless `emit` is injected.
    init(
        mode: Mode,
        groups: Set<EventGroup> = ConsoleSink.defaultGroups,
        emit: (@Sendable (String) -> Void)? = nil
    ) {
        self.mode = mode
        self.groups = groups
        self.emit = emit ?? Self.defaultEmit(for: mode)
    }

    func receive(_ event: EventBusEvent) async {
        guard groups.contains(event.group) else { return }
        switch mode {
        case .human:
            emit(Self.humanLine(for: event))
        case .json:
            if let line = Self.jsonLine(for: event) {
                emit(line)
            }
        }
    }

    /// The formatted human line: time, group, domain, name, and the params
    /// as a sorted `key=value` list.
    static func humanLine(for event: EventBusEvent) -> String {
        let time = event.date.formatted(date: .omitted, time: .standard)
        let params = event.params.map { params in
            " " + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        } ?? ""
        return "\(time) \(event.group.rawValue) \(event.domain.rawValue) \(event.name)\(params)"
    }

    /// The event as one NDJSON line, or nil if encoding is impossible —
    /// an output problem must never take down the process.
    static func jsonLine(for event: EventBusEvent) -> String? {
        guard let data = try? encoder.encode(JSONRecord(event)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The mode's default output: standard error for human lines, standard
    /// output for NDJSON records.
    private static func defaultEmit(for mode: Mode) -> @Sendable (String) -> Void {
        switch mode {
        case .human:
            return { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        case .json:
            return { line in print(line) }
        }
    }
}
