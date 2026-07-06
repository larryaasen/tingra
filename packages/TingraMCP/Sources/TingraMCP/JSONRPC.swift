//
//  JSONRPC.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// A JSON-RPC 2.0 request/response identifier: a string or an integer (the
/// spec also permits null, which this daemon never issues).
///
/// The daemon echoes a request's id verbatim on its response, so the id is
/// carried as-is rather than normalized.
public enum JSONRPCID: Sendable, Equatable {
    /// A numeric id.
    case number(Int)

    /// A string id.
    case string(String)
}

extension JSONRPCID: Codable {
    /// Decodes an id from either a JSON number or string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A JSON-RPC id must be a number or a string."
            )
        }
    }

    /// Encodes the id as the bare number or string it holds.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// The standard JSON-RPC 2.0 error codes the daemon uses, plus the meaning
/// each carries (see the JSON-RPC 2.0 specification, section 5.1).
///
/// These describe *protocol* faults — a malformed message, an unknown
/// method, bad params. A tool that runs and reports a failure is not a
/// protocol error: it returns a normal result with `isError` set, keyed off
/// the ``ErrorIdentifier`` registry (see ``MCPToolResult`` and MCP.md,
/// "Errors that teach").
public enum JSONRPCErrorCode: Int, Sendable {
    /// Invalid JSON was received.
    case parseError = -32700

    /// The JSON sent is not a valid request object.
    case invalidRequest = -32600

    /// The method does not exist.
    case methodNotFound = -32601

    /// Invalid method parameters.
    case invalidParams = -32602

    /// An internal JSON-RPC error.
    case internalError = -32603
}

/// A JSON-RPC 2.0 error object, carried in a response's `error` member.
public struct JSONRPCError: Sendable, Equatable, Codable {
    /// The numeric error code (see ``JSONRPCErrorCode``).
    public let code: Int

    /// A short human-readable description of the error.
    public let message: String

    /// Optional structured detail about the error.
    public let data: JSONValue?

    /// Creates an error object.
    ///
    /// - Parameters:
    ///   - code: The numeric error code.
    ///   - message: A short human-readable description.
    ///   - data: Optional structured detail.
    public init(code: JSONRPCErrorCode, message: String, data: JSONValue? = nil) {
        self.code = code.rawValue
        self.message = message
        self.data = data
    }
}

/// An incoming JSON-RPC message the daemon receives from a client: a request
/// (has both `method` and `id`) or a notification (has `method`, no `id`).
///
/// A message with an `id` but no `method` is a *response* to a
/// server-initiated request; the v1 daemon initiates none, so such messages
/// decode with a nil `method` and are ignored by the session.
public struct JSONRPCIncoming: Sendable, Decodable {
    /// The protocol version tag; must be `"2.0"`.
    public let jsonrpc: String

    /// The request/response id, absent on a notification.
    public let id: JSONRPCID?

    /// The method name, absent on a client response the daemon does not act on.
    public let method: String?

    /// The method parameters, if any.
    public let params: JSONValue?

    /// Whether this message expects a response (a request, not a notification).
    public var isRequest: Bool { id != nil && method != nil }
}

/// A JSON-RPC 2.0 response the daemon sends: exactly one of `result` or
/// `error` is present, and `id` echoes the request's id.
public struct JSONRPCResponse: Sendable, Encodable {
    /// The protocol version tag, always `"2.0"`.
    public let jsonrpc = "2.0"

    /// The id echoed from the request.
    public let id: JSONRPCID

    /// The success result, present when the call succeeded.
    public let result: JSONValue?

    /// The error, present when the call failed at the protocol level.
    public let error: JSONRPCError?

    /// The stable JSON keys.
    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    /// Creates a success response echoing `id` with `result`.
    public static func success(id: JSONRPCID, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    /// Creates a failure response echoing `id` with a protocol `error`.
    public static func failure(id: JSONRPCID, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }

    /// Creates a response directly.
    private init(id: JSONRPCID, result: JSONValue?, error: JSONRPCError?) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// A JSON-RPC 2.0 notification the daemon sends: a method call with no `id`,
/// so the client sends no response. Status changes reach connected sessions
/// this way (MCP.md, "Sessions and concurrency").
public struct JSONRPCNotification: Sendable, Encodable {
    /// The protocol version tag, always `"2.0"`.
    public let jsonrpc = "2.0"

    /// The notification method name, e.g. `notifications/message`.
    public let method: String

    /// The notification parameters, if any.
    public let params: JSONValue?

    /// The stable JSON keys.
    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    /// Creates a notification.
    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}
