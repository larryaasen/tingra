//
//  TransitionTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraComposition

/// Verifies ``Transition``'s equality and its persisted-project-contract
/// Codable round-trip (CLAUDE.md, "Data Models"), matching the coverage
/// `PresetCodableTests` gives `Preset`/`Shot`/`Layer`.
@Suite("Transition")
struct TransitionTests {
    @Test("a cut round-trips through JSON unchanged")
    func cutRoundTrips() throws {
        let data = try JSONEncoder().encode(Transition.cut)
        let decoded = try JSONDecoder().decode(Transition.self, from: data)
        #expect(decoded == .cut)
    }

    @Test("a dissolve round-trips through JSON with its duration")
    func dissolveRoundTrips() throws {
        let transition = Transition.dissolve(duration: 0.75)
        let data = try JSONEncoder().encode(transition)
        let decoded = try JSONDecoder().decode(Transition.self, from: data)
        #expect(decoded == transition)
    }

    @Test("a cut encodes only the kind key, no duration")
    func cutEncodesKindOnly() throws {
        let data = try JSONEncoder().encode(Transition.cut)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "cut")
        #expect(object["durationSeconds"] == nil)
    }

    @Test("a dissolve without a durationSeconds key decodes to the default duration")
    func dissolveOptionalDurationDefaults() throws {
        let json = Data(#"{"kind":"dissolve"}"#.utf8)
        let decoded = try JSONDecoder().decode(Transition.self, from: json)
        #expect(decoded == .dissolve(duration: Transition.defaultDissolveDuration))
    }

    @Test("decoding an unknown kind throws a dataCorrupted error")
    func unknownKindThrows() throws {
        let json = Data(#"{"kind":"wipe"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Transition.self, from: json)
        }
    }

    @Test("the dissolve convenience uses the default duration")
    func dissolveConvenienceUsesDefaultDuration() {
        #expect(Transition.dissolve == .dissolve(duration: Transition.defaultDissolveDuration))
    }

    @Test("transitions are equal only when their kind and (for a dissolve) duration match")
    func transitionEquality() {
        #expect(Transition.cut == Transition.cut)
        #expect(Transition.dissolve(duration: 0.5) == Transition.dissolve(duration: 0.5))
        #expect(Transition.cut != Transition.dissolve(duration: 0.5))
        #expect(Transition.dissolve(duration: 0.5) != Transition.dissolve(duration: 1.0))
    }
}
