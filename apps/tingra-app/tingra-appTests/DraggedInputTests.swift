//
//  DraggedInputTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit
import UniformTypeIdentifiers

@testable import TingraApp

@Suite("DraggedInput")
struct DraggedInputTests {
    @Test("a dragged input round-trips through its codable representation")
    func roundTrip() throws {
        let payload = DraggedInput(id: InputID(rawValue: "camera-1"))

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DraggedInput.self, from: data)

        #expect(decoded == payload)
        #expect(decoded.id.rawValue == "camera-1")
    }

    @Test("two payloads are equal only when they name the same input")
    func equality() {
        #expect(DraggedInput(id: InputID(rawValue: "a")) == DraggedInput(id: InputID(rawValue: "a")))
        #expect(DraggedInput(id: InputID(rawValue: "a")) != DraggedInput(id: InputID(rawValue: "b")))
    }

    @Test("the payload travels under the app's own exported type")
    func exportedType() {
        #expect(UTType.tingraInput.identifier == "com.moonwink.tingra.input")
        #expect(UTType.tingraInput.conforms(to: .data))
    }
}
