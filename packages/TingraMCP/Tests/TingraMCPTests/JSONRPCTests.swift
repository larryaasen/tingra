//
//  JSONRPCTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraMCP

/// The hand-rolled JSON-RPC 2.0 layer: decoding incoming requests and
/// notifications, and encoding responses/errors the documented way.
@Suite("JSON-RPC")
struct JSONRPCTests {
    @Test("a request decodes with its method and id")
    func decodesRequest() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8Data
        let message = try MessageCoder.decode(line)
        #expect(message.method == "tools/list")
        #expect(message.id == .number(1))
        #expect(message.isRequest)
    }

    @Test("a string id decodes as a string id")
    func decodesStringID() throws {
        let line = #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8Data
        let message = try MessageCoder.decode(line)
        #expect(message.id == .string("abc"))
    }

    @Test("a notification decodes with a method and no id")
    func decodesNotification() throws {
        let line = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8Data
        let message = try MessageCoder.decode(line)
        #expect(message.method == "notifications/initialized")
        #expect(message.id == nil)
        #expect(!message.isRequest)
    }

    @Test("a client response with an id and no method is not treated as a request")
    func clientResponseIsNotARequest() throws {
        let line = #"{"jsonrpc":"2.0","id":9,"result":{}}"#.utf8Data
        let message = try MessageCoder.decode(line)
        #expect(message.method == nil)
        #expect(!message.isRequest)
    }

    @Test("a success response encodes id and result and omits error")
    func encodesSuccess() throws {
        let response = JSONRPCResponse.success(id: .number(7), result: .object(["ok": .bool(true)]))
        let text = try MessageCoder.encode(response).utf8String
        #expect(text.contains(#""id":7"#))
        #expect(text.contains(#""result":{"ok":true}"#))
        #expect(!text.contains("error"))
    }

    @Test("an error response encodes the code and message")
    func encodesError() throws {
        let response = JSONRPCResponse.failure(
            id: .string("z"),
            error: JSONRPCError(code: .methodNotFound, message: "Unknown method 'x'.")
        )
        let text = try MessageCoder.encode(response).utf8String
        #expect(text.contains(#""id":"z""#))
        #expect(text.contains(#""code":-32601"#))
        #expect(text.contains("Unknown method"))
    }

    @Test("an encoded message carries no embedded newline (framing stays one line)")
    func encodedMessageIsOneLine() throws {
        let notification = JSONRPCNotification(
            method: "notifications/message", params: .object(["level": .string("info")]))
        let data = try MessageCoder.encode(notification)
        #expect(!data.contains(0x0A))
    }
}
