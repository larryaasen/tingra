//
//  PlugInLoaderTests.swift
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

/// The error a rejecting mock plug-in throws at activation.
private struct MockActivationError: Error, CustomStringConvertible {
    var description: String { "the mock plug-in rejected activation" }
}

/// A hardware-free input a mock plug-in contributes.
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

/// A plug-in that registers one mock input, or throws when told to.
private struct MockPlugIn: PlugIn {
    let id: PlugInID
    let name = "Mock Plug-In"

    /// The error to throw at activation, when set.
    var rejection: MockActivationError?

    func activate(in context: PlugInContext) async throws {
        if let rejection {
            throw rejection
        }
        try await context.inputs.register(MockInput(id: InputID(rawValue: "\(id.rawValue).input")))
    }
}

@Suite("PlugInLoader")
struct PlugInLoaderTests {
    @Test("every activating plug-in registers its inputs and is reported as activated")
    func activatesAndReportsPlugIns() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let registry = InputRegistry()
        let context = PlugInContext(
            eventBus: eventBus,
            clock: HostClock(),
            inputs: registry,
            outputs: OutputRegistry(),
            tools: ToolRegistry()
        )
        let plugIns: [any PlugIn] = [
            MockPlugIn(id: PlugInID(rawValue: "com.example.one")),
            MockPlugIn(id: PlugInID(rawValue: "com.example.two")),
        ]

        let activated = await PlugInLoader().activate(plugIns, in: context)
        eventBus.shutdown()

        #expect(activated.map(\.id) == plugIns.map(\.id))
        #expect(await registry.allInputs.count == 2)

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        let activations = received.filter { $0.name == "plugin.activated" }
        #expect(activations.count == 2)
        #expect(activations.allSatisfy { $0.group == .event && $0.domain == .plugIn })
    }

    @Test("a plug-in that throws is skipped and reported as an error event; the rest load normally")
    func throwingPlugInIsSkipped() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let registry = InputRegistry()
        let context = PlugInContext(
            eventBus: eventBus,
            clock: HostClock(),
            inputs: registry,
            outputs: OutputRegistry(),
            tools: ToolRegistry()
        )
        let plugIns: [any PlugIn] = [
            MockPlugIn(id: PlugInID(rawValue: "com.example.rejecting"), rejection: MockActivationError()),
            MockPlugIn(id: PlugInID(rawValue: "com.example.healthy")),
        ]

        let activated = await PlugInLoader().activate(plugIns, in: context)
        eventBus.shutdown()

        #expect(activated.map(\.id) == [PlugInID(rawValue: "com.example.healthy")])
        #expect(await registry.allInputs.count == 1)

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        let errors = received.filter { $0.group == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.name == "plugin.activation")
        #expect(errors.first?.params?["id"] == .string("com.example.rejecting"))
        #expect(errors.first?.params?["error"] == .string("the mock plug-in rejected activation"))
    }

    @Test("activating an empty plug-in list returns empty and emits nothing")
    func emptyListIsANoOp() async {
        let eventBus = EventBus()
        let events = eventBus.events()
        let context = PlugInContext(
            eventBus: eventBus,
            clock: HostClock(),
            inputs: InputRegistry(),
            outputs: OutputRegistry(),
            tools: ToolRegistry()
        )

        let activated = await PlugInLoader().activate([], in: context)
        eventBus.shutdown()

        #expect(activated.isEmpty)
        var count = 0
        for await _ in events {
            count += 1
        }
        #expect(count == 0)
    }
}
