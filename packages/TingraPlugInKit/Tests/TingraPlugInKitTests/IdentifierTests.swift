//
//  IdentifierTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraPlugInKit

@Suite("InputID")
struct InputIDTests {
    @Test("encodes as a bare JSON string and round-trips")
    func roundTrip() throws {
        let original = InputID(rawValue: "0x8020000005ac8514")

        let data = try JSONEncoder().encode([original])
        #expect(String(decoding: data, as: UTF8.self) == #"["0x8020000005ac8514"]"#)

        let decoded = try JSONDecoder().decode([InputID].self, from: data)
        #expect(decoded == [original])
    }

    @Test("identifiers with the same raw value are equal; different raw values are not")
    func equality() {
        #expect(InputID(rawValue: "a") == InputID(rawValue: "a"))
        #expect(InputID(rawValue: "a") != InputID(rawValue: "b"))
    }
}

@Suite("PlugInID")
struct PlugInIDTests {
    @Test("encodes as a bare JSON string and round-trips")
    func roundTrip() throws {
        let original = PlugInID(rawValue: "com.moonwink.tingra.input.camera")

        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([PlugInID].self, from: data)
        #expect(decoded == [original])
    }
}
