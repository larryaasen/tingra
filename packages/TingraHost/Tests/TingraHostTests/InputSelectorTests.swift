//
//  InputSelectorTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import TingraHost

/// A hardware-free stand-in for a real input, per the project's
/// generators-and-mocks testing rule.
private struct MockInput: Input {
    let id: InputID
    let name: String
    let kind: InputKind

    func start() async throws {}
    func stop() async {}
}

/// A registry loaded with the CLI.md example devices plus the generators.
private func makeRegistry() async throws -> InputRegistry {
    let registry = InputRegistry()
    let fixtures = [
        MockInput(id: InputID(rawValue: "0x8020000005ac8514"), name: "FaceTime HD Camera", kind: .camera),
        MockInput(id: InputID(rawValue: "0x14100000046d085e"), name: "Logitech BRIO", kind: .camera),
        MockInput(id: InputID(rawValue: "BuiltInMicrophoneDevice"), name: "MacBook Pro Microphone", kind: .microphone),
        MockInput(id: InputID(rawValue: "AppleUSBAudioEngine:Shure:MV7"), name: "Shure MV7", kind: .microphone),
        MockInput(id: InputID(rawValue: "bars"), name: "SMPTE Bars", kind: .generator),
    ]
    for fixture in fixtures {
        try await registry.register(fixture)
    }
    return registry
}

@Suite("InputRegistry canonical ordering")
struct InputOrderingTests {
    @Test("inputs(ofKind:) sorts by name, then identifier, and filters to the kind")
    func canonicalOrder() async throws {
        let registry = InputRegistry()
        try await registry.register(MockInput(id: InputID(rawValue: "z"), name: "Camera B", kind: .camera))
        try await registry.register(MockInput(id: InputID(rawValue: "a"), name: "Camera B", kind: .camera))
        try await registry.register(MockInput(id: InputID(rawValue: "m"), name: "Camera A", kind: .camera))
        try await registry.register(MockInput(id: InputID(rawValue: "mic"), name: "A Microphone", kind: .microphone))

        let cameras = await registry.inputs(ofKind: .camera)

        #expect(cameras.map(\.id.rawValue) == ["m", "a", "z"])
        #expect(cameras.map(\.name) == ["Camera A", "Camera B", "Camera B"])
    }
}

@Suite("Input selector resolution")
struct InputSelectorTests {
    @Test("an exact identifier from devices --json wins outright")
    func resolvesByExactID() async throws {
        let registry = try await makeRegistry()

        let input = try await registry.resolveInput(selector: "0x14100000046d085e", ofKind: .camera)

        #expect(input.name == "Logitech BRIO")
    }

    @Test("an integer selects by position in the canonical listing order")
    func resolvesByIndex() async throws {
        let registry = try await makeRegistry()

        // Listing order sorts by name: 0 FaceTime HD Camera, 1 Logitech BRIO.
        let first = try await registry.resolveInput(selector: "0", ofKind: .camera)
        let second = try await registry.resolveInput(selector: "1", ofKind: .camera)

        #expect(first.name == "FaceTime HD Camera")
        #expect(second.name == "Logitech BRIO")
    }

    @Test("a unique name substring matches case-insensitively")
    func resolvesByNameSubstring() async throws {
        let registry = try await makeRegistry()

        let camera = try await registry.resolveInput(selector: "brio", ofKind: .camera)
        let microphone = try await registry.resolveInput(selector: "MV7", ofKind: .microphone)

        #expect(camera.id == InputID(rawValue: "0x14100000046d085e"))
        #expect(microphone.name == "Shure MV7")
    }

    @Test("a substring matching several inputs throws ambiguous, listing the matches")
    func ambiguousSubstringThrows() async throws {
        let registry = try await makeRegistry()

        // "i" appears in both camera names (FaceTime, BRIO).
        await #expect(
            throws: InputSelectorError.ambiguous(
                selector: "i",
                kind: .camera,
                matches: ["FaceTime HD Camera", "Logitech BRIO"]
            )
        ) {
            try await registry.resolveInput(selector: "i", ofKind: .camera)
        }
    }

    @Test("a selector matching nothing throws notFound")
    func unknownSelectorThrows() async throws {
        let registry = try await makeRegistry()

        await #expect(throws: InputSelectorError.notFound(selector: "Elgato", kind: .camera)) {
            try await registry.resolveInput(selector: "Elgato", ofKind: .camera)
        }
    }

    @Test("an out-of-range index throws notFound")
    func outOfRangeIndexThrows() async throws {
        let registry = try await makeRegistry()

        await #expect(throws: InputSelectorError.notFound(selector: "5", kind: .camera)) {
            try await registry.resolveInput(selector: "5", ofKind: .camera)
        }
    }

    @Test("resolution never crosses kinds — a camera selector cannot land on a microphone")
    func kindIsolation() async throws {
        let registry = try await makeRegistry()

        await #expect(throws: InputSelectorError.notFound(selector: "Shure", kind: .camera)) {
            try await registry.resolveInput(selector: "Shure", ofKind: .camera)
        }
    }

    @Test("generators resolve by their stable identifiers")
    func generatorResolvesByID() async throws {
        let registry = try await makeRegistry()

        let bars = try await registry.resolveInput(selector: "bars", ofKind: .generator)

        #expect(bars.name == "SMPTE Bars")
    }

    @Test("each selector error maps to its stable error identifier")
    func identifierMapping() {
        #expect(InputSelectorError.notFound(selector: "x", kind: .camera).identifier == .inputNotFound)
        #expect(
            InputSelectorError.ambiguous(selector: "x", kind: .camera, matches: []).identifier == .inputAmbiguous
        )
    }

    @Test("descriptions name the selector and the fix")
    func descriptionsAreDeveloperFacing() {
        let notFound = String(describing: InputSelectorError.notFound(selector: "Elgato", kind: .camera))
        #expect(notFound.contains("Elgato"))
        #expect(notFound.contains("tingra-cli devices"))
        let ambiguous = String(
            describing: InputSelectorError.ambiguous(selector: "cam", kind: .camera, matches: ["A", "B"])
        )
        #expect(ambiguous.contains("A, B"))
    }
}
