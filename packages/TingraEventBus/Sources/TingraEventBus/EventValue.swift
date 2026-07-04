//
//  EventValue.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A structured event parameter value.
///
/// Deliberately small — string, integer, double, boolean — so every event
/// payload is `Sendable` and serializes trivially to NDJSON for the console
/// sink's `--json` mode (see EVENTS.md).
public enum EventValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension EventValue: Codable {
    /// Encodes as the bare JSON value (`"live"`, `4500`, `29.97`, `true`),
    /// never a keyed wrapper, so NDJSON output reads naturally.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: a JSON `true` must not decode as a number, and a
        // JSON `1` must stay an integer rather than widening to a double.
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "An EventValue must be a JSON string, number, or boolean."
            )
        }
    }
}

// Literal conformances so call sites read naturally:
// `params: ["bitrate": 4500, "codec": "h264"]`.

extension EventValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension EventValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension EventValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension EventValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
