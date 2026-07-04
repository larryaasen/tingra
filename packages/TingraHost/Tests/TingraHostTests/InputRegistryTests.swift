//
//  InputRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
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
    let name = "Mock Camera"
    let kind = InputKind.camera

    func start() async throws {}

    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

@Suite("InputRegistry")
struct InputRegistryTests {
    @Test("a registered input is resolvable by its identifier")
    func registerAndResolve() async throws {
        let registry = InputRegistry()
        let input = MockInput(id: InputID(rawValue: "mock.camera.0"))

        try await registry.register(input)

        let resolved = await registry.input(withID: InputID(rawValue: "mock.camera.0"))
        #expect(resolved?.id == input.id)
    }

    @Test("an unknown identifier resolves to nil")
    func unknownIdentifierResolvesToNil() async {
        let registry = InputRegistry()
        let resolved = await registry.input(withID: InputID(rawValue: "mock.absent"))
        #expect(resolved == nil)
    }

    @Test("registering a duplicate identifier throws")
    func duplicateRegistrationThrows() async throws {
        let registry = InputRegistry()
        let id = InputID(rawValue: "mock.camera.0")
        try await registry.register(MockInput(id: id))

        await #expect(throws: InputRegistryError.duplicateInput(id)) {
            try await registry.register(MockInput(id: id))
        }
    }

    @Test("allInputs returns every registered input")
    func allInputsReturnsEverything() async throws {
        let registry = InputRegistry()
        try await registry.register(MockInput(id: InputID(rawValue: "mock.camera.0")))
        try await registry.register(MockInput(id: InputID(rawValue: "mock.mic.0")))

        let all = await registry.allInputs
        #expect(all.count == 2)
    }
}
