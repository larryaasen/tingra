//
//  JSONValue.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// An arbitrary JSON value: the currency of the MCP tool seam.
///
/// A ``Tool`` receives its arguments as a ``JSONValue`` and returns its
/// result as one, and tool input schemas are expressed as `JSONValue`
/// objects (JSON Schema). It is deliberately more general than the event
/// bus's `EventValue`: events carry the control plane and stay scalar-only
/// (see EVENTS.md), while tool payloads are arbitrary nested JSON matching
/// the MCP wire format. The two types stay separate so neither layer's
/// rules leak into the other.
///
/// A stability-contract type (see ARCHITECTURE.md, "Plug-in API stability
/// and versioning"): it is the shape third-party tools speak, so it encodes
/// as natural JSON — a `.string` is a bare JSON string, an `.object` a bare
/// JSON object — never a keyed wrapper.
public enum JSONValue: Sendable, Equatable {
    /// JSON `null`.
    case null

    /// A JSON boolean.
    case bool(Bool)

    /// A JSON integer (kept distinct from ``double(_:)`` so `1` never
    /// silently widens to `1.0` on a round trip).
    case int(Int)

    /// A JSON floating-point number.
    case double(Double)

    /// A JSON string.
    case string(String)

    /// A JSON array.
    case array([JSONValue])

    /// A JSON object, keyed by member name.
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    /// Encodes as the bare JSON value it represents, never a keyed wrapper,
    /// so the wire format reads as ordinary JSON.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// Decodes the bare JSON value into the narrowest matching case.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: `null` first, then `bool` before the numeric cases
        // (a JSON `true` must not decode as a number), then `int` before
        // `double` so whole numbers stay integers on a round trip.
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A JSONValue must be a JSON null, boolean, number, string, array, or object."
            )
        }
    }
}

extension JSONValue {
    /// The object's members, or nil if this value is not an object — the
    /// common case for reading a tool's argument dictionary.
    public var objectValue: [String: JSONValue]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    /// The string value, or nil if this value is not a string.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// The integer value, or nil if this value is not an integer.
    public var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    /// The boolean value, or nil if this value is not a boolean.
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// The member named `key` when this value is an object, or nil when it
    /// is not an object or has no such member.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// Literal conformances so building schemas and results reads naturally:
// `["type": "object", "required": ["url"]]`.

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { first, _ in first }))
    }
}
