//
//  InputRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraHost

/// A hardware-free stand-in for a real input, per the project's
/// generators-and-mocks testing rule.
private struct MockInput: Input {
    let id: InputID
    let name = "Mock Camera"
    let kind = InputKind.camera
    let media = InputMedia.video

    func start() async throws {}

    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

/// An input that declares no media — the plug-in defect the registry
/// reports. It keeps the seam's `media` default rather than overriding it,
/// so this is exactly what a conformance written without the property does.
private struct UndeclaredMediaInput: Input {
    let id = InputID(rawValue: "mock.undeclared")
    let name = "Undeclared"
    let kind = InputKind.generator

    func start() async throws {}
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

    @Test("unregistering removes the input; unknown identifiers are harmless")
    func unregisterRemovesInput() async throws {
        let registry = InputRegistry()
        let id = InputID(rawValue: "mock.camera.0")
        try await registry.register(MockInput(id: id))

        await registry.unregister(id)
        #expect(await registry.input(withID: id) == nil)

        // Disconnection is a normal event — removing again does nothing.
        await registry.unregister(id)
        #expect(await registry.allInputs.isEmpty)
    }

    @Test("allInputs returns every registered input")
    func allInputsReturnsEverything() async throws {
        let registry = InputRegistry()
        try await registry.register(MockInput(id: InputID(rawValue: "mock.camera.0")))
        try await registry.register(MockInput(id: InputID(rawValue: "mock.mic.0")))

        let all = await registry.allInputs
        #expect(all.count == 2)
    }

    @Test("an input declaring no media registers successfully and is reported")
    func undeclaredMediaIsReportedNotRejected() async throws {
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }
        let registry = InputRegistry(eventBus: eventBus)
        let input = UndeclaredMediaInput()

        // Registration succeeds: a plug-in's omission must not cost the host
        // a capability, and the input stays resolvable by identifier.
        try await registry.register(input)
        #expect(await registry.input(withID: input.id) != nil)

        let reported = await eventually { !events.named("input.noMedia").isEmpty }
        #expect(reported)
        let event = try #require(events.named("input.noMedia").first)
        #expect(event.group == .error)
        #expect(event.domain == .capture)
        #expect(event.params?["id"] == .string("mock.undeclared"))
        #expect(event.params?["name"] == .string("Undeclared"))
    }

    @Test("an input declaring media is not reported")
    func declaredMediaIsNotReported() async throws {
        let eventBus = EventBus()
        let events = CollectedEvents()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }
        let registry = InputRegistry(eventBus: eventBus)

        try await registry.register(MockInput(id: InputID(rawValue: "mock.camera.0")))

        // Give the bus the same opportunity to deliver as the test above.
        _ = await eventually(within: 0.1) { !events.named("input.noMedia").isEmpty }
        #expect(events.named("input.noMedia").isEmpty)
    }

    @Test("a registry with no event bus still registers an input declaring no media")
    func undeclaredMediaWithoutEventBus() async throws {
        let registry = InputRegistry()
        let input = UndeclaredMediaInput()

        try await registry.register(input)

        #expect(await registry.input(withID: input.id) != nil)
    }
}
