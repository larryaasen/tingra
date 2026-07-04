//
//  ErrorIdentifierTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraPlugInKit

@Suite("ErrorIdentifier")
struct ErrorIdentifierTests {
    @Test("the registered identifiers keep their shipped raw values — append-only, never renamed")
    func registeredRawValuesAreStable() {
        // These pairs are the CLI.md registry verbatim. A mismatch here means
        // a shipped identifier was renamed, which breaks the scripting and
        // MCP contract — fix the code, never this test.
        #expect(ErrorIdentifier.invalidArgument.rawValue == "invalidArgument")
        #expect(ErrorIdentifier.inputNotFound.rawValue == "inputNotFound")
        #expect(ErrorIdentifier.inputAmbiguous.rawValue == "inputAmbiguous")
        #expect(ErrorIdentifier.authorizationDenied.rawValue == "authorizationDenied")
        #expect(ErrorIdentifier.pipelineError.rawValue == "pipelineError")
        #expect(ErrorIdentifier.connectionFailed.rawValue == "connectionFailed")
        #expect(ErrorIdentifier.connectionLost.rawValue == "connectionLost")
    }

    @Test("encodes as a bare JSON string and round-trips")
    func roundTrip() throws {
        let original = ErrorIdentifier.authorizationDenied

        let data = try JSONEncoder().encode([original])
        #expect(String(decoding: data, as: UTF8.self) == #"["authorizationDenied"]"#)

        let decoded = try JSONDecoder().decode([ErrorIdentifier].self, from: data)
        #expect(decoded == [original])
    }

    @Test("identifiers with the same raw value are equal; different raw values are not")
    func equality() {
        #expect(ErrorIdentifier.inputNotFound == ErrorIdentifier(rawValue: "inputNotFound"))
        #expect(ErrorIdentifier.inputNotFound != ErrorIdentifier.inputAmbiguous)
    }
}
