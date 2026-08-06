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

/// Rejects the input at a chosen position, standing in for a registry that
/// already holds one of these identifiers — the only way `register` throws.
private actor RejectingInputRegistrar: InputRegistering {
    /// The inputs currently registered, in registration order.
    private(set) var registered: [any Input] = []

    /// The zero-based registration attempt that is rejected.
    private let rejectAt: Int

    /// Attempts made so far, accepted or not.
    private var attempts = 0

    /// The error a rejected registration throws.
    struct DuplicateIdentifier: Error {}

    /// Creates a registrar that rejects the `rejectAt`-th registration.
    init(rejectAt: Int) {
        self.rejectAt = rejectAt
    }

    func register(_ input: any Input) throws {
        defer { attempts += 1 }
        guard attempts != rejectAt else { throw DuplicateIdentifier() }
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

    /// Never called by this plug-in.
    func register(_ provider: any RecordingServiceProvider) async throws {}
}

/// A no-op effect registration seam — the generator plug-in never registers
/// effects.
private struct UnusedEffectRegistrar: EffectRegistering {
    /// Never called by this plug-in.
    func register(_ provider: any AudioEffectProvider) async throws {}

    /// Never called by this plug-in.
    func register(_ provider: any VideoEffectProvider) async throws {}
}

/// A no-op tool registration seam — the generator plug-in never registers
/// tools.
private struct UnusedToolRegistrar: ToolRegistering {
    /// Never called by this plug-in.
    func register(_ tool: any Tool) async throws {}
}

@Suite("GeneratorPlugIn")
struct GeneratorPlugInTests {
    @Test("activation registers the built-in generators with their stable identifiers")
    func activationRegistersGenerators() async throws {
        let plugIn = GeneratorPlugIn()
        let registrar = MockInputRegistrar()
        let context = PlugInContext(
            eventBus: EventBus(),
            clock: SyntheticClock(),
            inputs: registrar,
            outputs: UnusedOutputRegistrar(),
            effects: UnusedEffectRegistrar(),
            tools: UnusedToolRegistrar()
        )

        try await plugIn.activate(in: context)

        let registered = await registrar.registered
        try #require(registered.count == 6)
        #expect(registered[0].id == BarsGenerator.inputID)
        #expect(registered[0].kind == .generator)
        #expect(registered[1].id == AlignmentGenerator.inputID)
        #expect(registered[1].kind == .generator)
        #expect(registered[2].id == PlugeGenerator.inputID)
        #expect(registered[2].kind == .generator)
        #expect(registered[3].id == PlugeStrictGenerator.inputID)
        #expect(registered[3].kind == .generator)
        #expect(registered[4].id == BlackGenerator.inputID)
        #expect(registered[4].kind == .generator)
        #expect(registered[5].id == ToneGenerator.inputID)
        #expect(registered[5].kind == .generator)
    }

    @Test("every generator declares the media it produces, which its kind cannot")
    func generatorsDeclareTheirMedia() async throws {
        let plugIn = GeneratorPlugIn()
        let registrar = MockInputRegistrar()
        let context = PlugInContext(
            eventBus: EventBus(),
            clock: SyntheticClock(),
            inputs: registrar,
            outputs: UnusedOutputRegistrar(),
            effects: UnusedEffectRegistrar(),
            tools: UnusedToolRegistrar()
        )

        try await plugIn.activate(in: context)

        let registered = await registrar.registered
        try #require(registered.count == 6)
        // Every generator shares one kind, so the kind cannot separate the
        // five video generators from the tone — the media declaration is the
        // only thing that can, and is what admits bars to a layer and tone
        // to a channel strip.
        #expect(registered[0].media == .video)
        #expect(registered[1].media == .video)
        #expect(registered[2].media == .video)
        #expect(registered[3].media == .video)
        #expect(registered[4].media == .video)
        #expect(registered[5].media == .audio)
        #expect(registered.allSatisfy { !$0.media.isEmpty })
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
            outputs: UnusedOutputRegistrar(),
            effects: UnusedEffectRegistrar(),
            tools: UnusedToolRegistrar()
        )

        try await plugIn.activate(in: context)
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        #expect(received.count == 6)
        #expect(received.allSatisfy { $0.group == .trace && $0.domain == .capture && $0.name == "input.registered" })
        #expect(received.first?.params?["id"] == .string("bars"))
        #expect(received.dropFirst().first?.params?["id"] == .string("alignment"))
        #expect(received.dropFirst(2).first?.params?["id"] == .string("pluge"))
        #expect(received.dropFirst(3).first?.params?["id"] == .string("pluge-strict"))
        #expect(received.dropFirst(4).first?.params?["id"] == .string("black"))
        #expect(received.last?.params?["id"] == .string("tone"))
    }

    @Test("a rejection partway through leaves nothing registered")
    func rejectionRollsBackEarlierRegistrations() async throws {
        // The fourth generator is rejected: three are already in the registry
        // by then, which is exactly the partially-activated state the plug-in
        // used to leave behind.
        let registrar = RejectingInputRegistrar(rejectAt: 3)
        let plugIn = GeneratorPlugIn()
        let context = PlugInContext(
            eventBus: EventBus(),
            clock: SyntheticClock(),
            inputs: registrar,
            outputs: UnusedOutputRegistrar(),
            effects: UnusedEffectRegistrar(),
            tools: UnusedToolRegistrar()
        )

        await #expect(throws: RejectingInputRegistrar.DuplicateIdentifier.self) {
            try await plugIn.activate(in: context)
        }

        let registered = await registrar.registered
        #expect(registered.isEmpty)
    }

    @Test("a rejection on the very first generator leaves the registry untouched")
    func rejectionOnFirstRegistrationRollsBackNothing() async throws {
        let registrar = RejectingInputRegistrar(rejectAt: 0)
        let plugIn = GeneratorPlugIn()
        let context = PlugInContext(
            eventBus: EventBus(),
            clock: SyntheticClock(),
            inputs: registrar,
            outputs: UnusedOutputRegistrar(),
            effects: UnusedEffectRegistrar(),
            tools: UnusedToolRegistrar()
        )

        await #expect(throws: RejectingInputRegistrar.DuplicateIdentifier.self) {
            try await plugIn.activate(in: context)
        }

        let registered = await registrar.registered
        #expect(registered.isEmpty)
    }

    @Test("the rollback is reported, so the loader's error is not the only record")
    func rollbackIsReported() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let plugIn = GeneratorPlugIn()
        let context = PlugInContext(
            eventBus: eventBus,
            clock: SyntheticClock(),
            inputs: RejectingInputRegistrar(rejectAt: 2),
            outputs: UnusedOutputRegistrar(),
            effects: UnusedEffectRegistrar(),
            tools: UnusedToolRegistrar()
        )

        await #expect(throws: RejectingInputRegistrar.DuplicateIdentifier.self) {
            try await plugIn.activate(in: context)
        }
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        // Two registrations landed and were reported, then the rollback.
        #expect(received.count == 3)
        let rollback = received.last
        #expect(rollback?.group == .trace)
        #expect(rollback?.domain == .capture)
        #expect(rollback?.name == "input.registrationRolledBack")
        #expect(rollback?.params?["removed"] == .int(2))
    }

    @Test("a successful activation reports no rollback")
    func successfulActivationDoesNotReportRollback() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let plugIn = GeneratorPlugIn()
        let context = PlugInContext(
            eventBus: eventBus,
            clock: SyntheticClock(),
            inputs: MockInputRegistrar(),
            outputs: UnusedOutputRegistrar(),
            effects: UnusedEffectRegistrar(),
            tools: UnusedToolRegistrar()
        )

        try await plugIn.activate(in: context)
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        #expect(received.allSatisfy { $0.name == "input.registered" })
    }

    @Test("the plug-in carries its stable reverse-DNS identifier")
    func plugInIdentifier() {
        let plugIn = GeneratorPlugIn()
        #expect(plugIn.id == PlugInID(rawValue: "com.moonwink.tingra.generators"))
        #expect(plugIn.name == "Generators")
    }
}
