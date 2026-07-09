//
//  StatusNotification.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

extension JSONValue {
    /// The event bus's scalar param value as a JSON value — the bridge from
    /// the control-plane `EventValue` (EVENTS.md) to the tool/JSON-RPC layer.
    init(_ value: EventValue) {
        switch value {
        case .string(let string): self = .string(string)
        case .int(let int): self = .int(int)
        case .double(let double): self = .double(double)
        case .bool(let bool): self = .bool(bool)
        }
    }
}

/// Renders a retained status event as the params of an MCP
/// `notifications/message` (the standard logging notification): `level` from
/// the event group, a fixed `logger`, and `data` carrying the event's name,
/// domain, and params. This is how status changes reach connected sessions
/// without polling (MCP.md, "Sessions and concurrency"); secrets must never
/// have become a param in the first place (EVENTS.md, Redaction).
enum StatusNotification {
    /// The `notifications/message` params for a status event.
    static func params(for event: EventBusEvent) -> JSONValue {
        var data: [String: JSONValue] = [
            "name": .string(event.name),
            "domain": .string(event.domain.rawValue),
        ]
        if let params = event.params {
            data["params"] = .object(params.mapValues { JSONValue($0) })
        }
        return .object([
            "level": .string(event.group == .error ? "error" : "info"),
            "logger": .string("tingra"),
            "data": .object(data),
        ])
    }
}
