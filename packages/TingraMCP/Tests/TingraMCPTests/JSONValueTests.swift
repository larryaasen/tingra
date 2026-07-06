//
//  JSONValueTests.swift
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

/// The JSON tool-payload value: natural encoding and lossless round trips —
/// it is the shape third-party tools speak, a stability contract.
@Suite("JSONValue")
struct JSONValueTests {
    /// Encodes and decodes a value, returning the decoded result.
    private func roundTrip(_ value: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("scalars round-trip without changing case")
    func scalarRoundTrip() throws {
        #expect(try roundTrip(.string("live")) == .string("live"))
        #expect(try roundTrip(.int(4500)) == .int(4500))
        #expect(try roundTrip(.double(29.97)) == .double(29.97))
        #expect(try roundTrip(.bool(true)) == .bool(true))
        #expect(try roundTrip(.null) == .null)
    }

    @Test("a whole number stays an int and does not widen to a double")
    func integerDoesNotWiden() throws {
        #expect(try roundTrip(.int(1)) == .int(1))
    }

    @Test("nested objects and arrays round-trip")
    func nestedRoundTrip() throws {
        let value: JSONValue = .object([
            "cameras": .array([
                .object(["index": .int(0), "name": .string("BRIO"), "id": .string("0x14")])
            ]),
            "enabled": .bool(true),
        ])
        #expect(try roundTrip(value) == value)
    }

    @Test("a value encodes as bare JSON, not a keyed wrapper")
    func encodesAsBareJSON() throws {
        let data = try JSONEncoder().encode(JSONValue.object(["a": .int(1)]))
        #expect(data.utf8String == #"{"a":1}"#)
    }

    @Test("dictionary and array literals build the matching value")
    func literals() {
        let value: JSONValue = ["type": "object", "count": 2, "ok": true]
        #expect(value["type"] == .string("object"))
        #expect(value["count"]?.intValue == 2)
        #expect(value["ok"]?.boolValue == true)
    }

    @Test("accessors return nil for a mismatched shape")
    func accessorsMismatch() {
        #expect(JSONValue.int(1).stringValue == nil)
        #expect(JSONValue.string("x").objectValue == nil)
        #expect(JSONValue.string("x")["key"] == nil)
    }
}
