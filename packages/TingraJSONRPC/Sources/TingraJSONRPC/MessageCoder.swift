//
//  MessageCoder.swift
//  TingraJSONRPC
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Encodes outgoing JSON-RPC messages and decodes incoming ones, with one
/// shared coder configuration: sorted keys (so a payload is stable for
/// tests and logs) and unescaped slashes (so method names such as
/// `tools/call` read as written).
public enum MessageCoder {
    /// The shared encoder.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The shared decoder.
    private static let decoder = JSONDecoder()

    /// Encodes a message as one JSON payload.
    ///
    /// - Parameter message: The response, notification, or request to encode.
    /// - Throws: An `EncodingError` if the message cannot be encoded.
    public static func encode(_ message: some Encodable) throws -> Data {
        try encoder.encode(message)
    }

    /// Decodes one JSON payload as an incoming JSON-RPC message.
    ///
    /// - Parameter payload: The payload, without framing.
    /// - Throws: A `DecodingError` if the payload is not a JSON-RPC message.
    public static func decode(_ payload: Data) throws -> JSONRPCIncoming {
        try decoder.decode(JSONRPCIncoming.self, from: payload)
    }
}
