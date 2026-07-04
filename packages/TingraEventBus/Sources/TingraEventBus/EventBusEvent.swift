//
//  EventBusEvent.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// One structured event on the event bus.
///
/// Code emits events; sinks decide what becomes a log line, a `--json`
/// record, or MCP status (see EVENTS.md). Events carry the control plane
/// only — never per frame traffic.
public struct EventBusEvent: Sendable, Codable, Equatable {
    /// When the event was emitted, on the wall clock (display only — media
    /// timing uses the master clock, see CLOCK.md).
    public let date: Date

    /// The routing axis: what kind of event this is.
    public let group: EventGroup

    /// The attribution axis: which part of the system emitted it.
    public let domain: EventDomain

    /// Dotted lowercase identifier, e.g. `stream.started`,
    /// `device.disconnected` (letters, digits, `_`, `.`).
    public let name: String

    /// Structured payload. Values matching the sensitive key list are
    /// redacted by the bus before any sink sees them.
    public let params: [String: EventValue]?

    /// The emitting call site, captured via `#fileID`/`#function` default
    /// arguments on `EventBus.send`.
    public let from: String

    /// The stable JSON key for each property. JSON keys are a scripting
    /// contract (CLAUDE.md, Data Models): mapped explicitly, never via a
    /// key-conversion strategy.
    private enum CodingKeys: String, CodingKey {
        case date
        case group
        case domain
        case name
        case params
        case from
    }
}
