//
//  JSONCoding.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Encodes a ``JSONValue`` to compact JSON text — the human-readable text
/// block inside a `tools/call` result, and a small helper anywhere a
/// value needs a string rendering.
enum JSONText {
    /// The shared compact encoder: sorted keys (so the same value always
    /// renders identically, which keeps tests deterministic) and unescaped
    /// slashes (URLs stay readable).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The value as compact JSON text, or `"{}"` if it somehow cannot be
    /// encoded — a rendering helper must never throw into the message path.
    static func encode(_ value: JSONValue) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The JSON-RPC message codec. Messages travel newline-delimited — one
/// message per line, no embedded newlines, exactly as the MCP stdio
/// transport defines (MCP.md, "The transport") — but the newline framing
/// itself is the transport's concern, so this codec deals only in a
/// message's compact JSON payload. Owning it lets direct socket clients
/// speak the documented wire format.
enum MessageCoder {
    /// The compact encoder for outgoing messages (sorted keys for stable
    /// output, unescaped slashes for readable URLs).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The decoder for incoming messages.
    private static let decoder = JSONDecoder()

    /// Encodes an outgoing message to its compact JSON payload (no trailing
    /// newline — the transport appends the frame delimiter).
    ///
    /// - Throws: An encoding error if the value cannot be serialized (never
    ///   expected for the daemon's own message types).
    static func encode(_ message: some Encodable) throws -> Data {
        try encoder.encode(message)
    }

    /// Decodes one line of JSON (without its trailing newline) into an
    /// incoming JSON-RPC message.
    ///
    /// - Throws: A decoding error if the line is not valid JSON-RPC.
    static func decode(_ line: Data) throws -> JSONRPCIncoming {
        try decoder.decode(JSONRPCIncoming.self, from: line)
    }
}
