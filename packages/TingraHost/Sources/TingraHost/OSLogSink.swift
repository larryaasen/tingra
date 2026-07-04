//
//  OSLogSink.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization
import TingraEventBus
import os

/// The always-on system-of-record sink (see EVENTS.md, "Sinks"): routes
/// every event to OSLog, where Console.app, `log stream`, and sysdiagnoses
/// can retrieve it.
///
/// `subsystem` is `com.moonwink.tingra`; `category` is the event's domain
/// (a 1:1 mapping). Group maps to level per the EVENTS.md table. The group
/// and name interpolate as public; params interpolate as `privacy:
/// .private` — redaction layer 3, keeping anything the bus-level redaction
/// missed out of retrievable logs on release builds.
public final class OSLogSink: EventSink {
    /// The OSLog subsystem every Tingra event lands under.
    static let subsystem = "com.moonwink.tingra"

    /// One `Logger` per domain, created on first use. Mutex protected —
    /// `receive` runs on the sink's consuming task, but the sink itself is
    /// `Sendable` and may be attached to more than one bus.
    private let loggers = Mutex<[EventDomain: Logger]>([:])

    /// Creates the sink. The host attaches one to its bus unconditionally.
    public init() {}

    public func receive(_ event: EventBusEvent) async {
        let logger = logger(for: event.domain)
        let params = event.params.map(Self.formatted) ?? ""
        logger.log(
            level: Self.level(for: event.group),
            "\(event.group.rawValue, privacy: .public) \(event.name, privacy: .public) \(params, privacy: .private)"
        )
    }

    /// The EVENTS.md group-to-level mapping: `app`, `event`, and `tap` log
    /// at info; `network` and `trace` at debug; `error` at error.
    static func level(for group: EventGroup) -> OSLogType {
        switch group {
        case .app, .event, .tap: .info
        case .network, .trace: .debug
        case .error: .error
        }
    }

    /// Renders params as a stable `key=value` list, sorted by key so the
    /// same event always logs the same line.
    static func formatted(_ params: [String: EventValue]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    /// The cached logger for a domain, creating it on first use.
    private func logger(for domain: EventDomain) -> Logger {
        loggers.withLock { store in
            if let logger = store[domain] {
                return logger
            }
            let logger = Logger(subsystem: Self.subsystem, category: domain.rawValue)
            store[domain] = logger
            return logger
        }
    }
}
