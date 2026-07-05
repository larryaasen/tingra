//
//  GeneratorPlugInTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

/// Collects registered inputs, standing in for the host's registry —
/// no engine dependency, per the package's seam-only design.
private actor MockInputRegistrar: InputRegistering {
    /// The inputs registered so far, in registration order.
    private(set) var registered: [any Input] = []

    func register(_ input: any Input) throws {
        registered.append(input)
    }

    func unregister(_ id: InputID) {
        registered.removeAll { $0.id == id }
    }
}

/// A no-op output registration seam — the generator plug-in never
/// registers outputs.
private struct UnusedOutputRegistrar: OutputRegistering {
    /// Never called by this plug-in.
    func register(_ provider: any StreamingServiceProvider) async throws {}
}

@Suite("GeneratorPlugIn")
struct GeneratorPlugInTests {
    @Test("activation registers the bars and tone generators with their stable identifiers")
    func activationRegistersGenerators() async throws {
        let plugIn = GeneratorPlugIn()
        let registrar = MockInputRegistrar()
        let context = PlugInContext(
            eventBus: EventBus(),
            clock: SyntheticClock(),
            inputs: registrar,
            outputs: UnusedOutputRegistrar()
        )

        try await plugIn.activate(in: context)

        let registered = await registrar.registered
        try #require(registered.count == 2)
        #expect(registered[0].id == BarsGenerator.inputID)
        #expect(registered[0].kind == .generator)
        #expect(registered[1].id == ToneGenerator.inputID)
        #expect(registered[1].kind == .generator)
    }

    @Test("each registration is reported as a trace event on the bus")
    func registrationEmitsTraceEvents() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let plugIn = GeneratorPlugIn()
        let context = PlugInContext(
            eventBus: eventBus,
            clock: SyntheticClock(),
            inputs: MockInputRegistrar(),
            outputs: UnusedOutputRegistrar()
        )

        try await plugIn.activate(in: context)
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        #expect(received.count == 2)
        #expect(received.allSatisfy { $0.group == .trace && $0.domain == .capture && $0.name == "input.registered" })
        #expect(received.first?.params?["id"] == .string("bars"))
        #expect(received.last?.params?["id"] == .string("tone"))
    }

    @Test("the plug-in carries its stable reverse-DNS identifier")
    func plugInIdentifier() {
        let plugIn = GeneratorPlugIn()
        #expect(plugIn.id == PlugInID(rawValue: "com.moonwink.tingra.generators"))
        #expect(plugIn.name == "Generators")
    }
}
