//
//  DisplayInputTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraCapturePlugIns

/// The fixture display, mirroring a built-in Mac display.
private let fixtureDisplay = DisplayDevice(
    uniqueID: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
    name: "Built-in Display",
    pixelWidth: 3456,
    pixelHeight: 2234
)

/// Collects registered inputs, standing in for the host's registry — no
/// engine dependency, per the package's seam-only design.
private actor MockDisplayRegistrar: InputRegistering {
    /// The inputs registered so far, in registration order.
    private(set) var registered: [any Input] = []

    /// The error to throw on the next registration, when set.
    private let rejection: (any Error)?

    /// Creates a registrar that accepts everything, or rejects with `rejection`.
    init(rejection: (any Error)? = nil) {
        self.rejection = rejection
    }

    func register(_ input: any Input) throws {
        if let rejection {
            throw rejection
        }
        registered.append(input)
    }

    func unregister(_ id: InputID) {
        registered.removeAll { $0.id == id }
    }
}

/// A fixed synthetic clock, per CLOCK.md's test substitution rule.
private struct SyntheticClock: EngineClock {
    var now: CMTime { .zero }

    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { $0.finish() }
    }
}

/// A no-op output registration seam — the capture plug-in never registers
/// outputs.
private struct UnusedOutputRegistrar: OutputRegistering {
    func register(_ provider: any StreamingServiceProvider) async throws {}
    func register(_ provider: any RecordingServiceProvider) async throws {}
}

/// A no-op tool registration seam — the capture plug-in never registers
/// tools.
private struct UnusedToolRegistrar: ToolRegistering {
    func register(_ tool: any Tool) async throws {}
}

/// Builds a context over a fresh bus and mock registrar.
private func makeContext(registrar: MockDisplayRegistrar, eventBus: EventBus = EventBus()) -> PlugInContext {
    PlugInContext(
        eventBus: eventBus,
        clock: SyntheticClock(),
        inputs: registrar,
        outputs: UnusedOutputRegistrar(),
        tools: UnusedToolRegistrar()
    )
}

@Suite("DisplayInput")
struct DisplayInputTests {
    @Test("start() throws authorizationDenied when Screen Recording is denied")
    func startThrowsWhenAuthorizationDenied() async {
        let input = DisplayInput(display: fixtureDisplay, requestAuthorization: { false })

        await #expect(throws: CaptureInputError.authorizationDenied(.display, input.id)) {
            try await input.start()
        }
    }

    @Test("the input carries the display's identifier, name, and the display kind")
    func identity() {
        let input = DisplayInput(display: fixtureDisplay, requestAuthorization: { false })
        #expect(input.id == InputID(rawValue: "37D8832A-2D66-02CA-B9F7-8F30A301B230"))
        #expect(input.name == "Built-in Display")
        #expect(input.kind == .display)
    }

    @Test("stop() before start is safe and finishes an attached stream")
    func stopBeforeStartIsSafe() async {
        let input = DisplayInput(display: fixtureDisplay, requestAuthorization: { false })
        let frames = input.frames()
        let consumer = Task {
            var count = 0
            for await _ in frames {
                count += 1
            }
            return count
        }

        await input.stop()
        await input.stop()

        #expect(await consumer.value == 0)
    }
}

@Suite("ScreenCaptureKitCapturePlugIn")
struct ScreenCaptureKitCapturePlugInTests {
    @Test("activation registers one display input per discovered display, preserving identifier, name, and kind")
    func activationRegistersDiscoveredDisplays() async throws {
        let plugIn = ScreenCaptureKitCapturePlugIn(enumerateDisplays: { [fixtureDisplay] })
        let registrar = MockDisplayRegistrar()

        try await plugIn.activate(in: makeContext(registrar: registrar))

        let registered = await registrar.registered
        try #require(registered.count == 1)
        #expect(registered[0].id == InputID(rawValue: "37D8832A-2D66-02CA-B9F7-8F30A301B230"))
        #expect(registered[0].name == "Built-in Display")
        #expect(registered[0].kind == .display)
        #expect(registered[0] is DisplayInput)
    }

    @Test("activation with no connected displays registers nothing")
    func activationWithNoDisplays() async throws {
        let plugIn = ScreenCaptureKitCapturePlugIn(enumerateDisplays: { [] })
        let registrar = MockDisplayRegistrar()

        try await plugIn.activate(in: makeContext(registrar: registrar))

        #expect(await registrar.registered.isEmpty)
    }

    @Test("each display discovery is reported as a trace event in the capture domain")
    func discoveryEmitsTraceEvents() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let plugIn = ScreenCaptureKitCapturePlugIn(enumerateDisplays: { [fixtureDisplay] })

        try await plugIn.activate(in: makeContext(registrar: MockDisplayRegistrar(), eventBus: eventBus))
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        let discoveries = received.filter { $0.name == "input.discovered" }
        #expect(discoveries.count == 1)
        #expect(discoveries.allSatisfy { $0.group == .trace && $0.domain == .capture })
        #expect(discoveries.first?.params?["kind"] == .string("display"))
    }

    @Test("a registry rejection propagates out of activation")
    func registryRejectionPropagates() async {
        let plugIn = ScreenCaptureKitCapturePlugIn(enumerateDisplays: { [fixtureDisplay] })
        let registrar = MockDisplayRegistrar(
            rejection: CaptureInputError.deviceUnavailable(InputID(rawValue: "any"))
        )

        await #expect(throws: (any Error).self) {
            try await plugIn.activate(in: makeContext(registrar: registrar))
        }
    }

    @Test("the plug-in carries its stable reverse-DNS identifier")
    func plugInIdentifier() {
        let plugIn = ScreenCaptureKitCapturePlugIn(enumerateDisplays: { [] })
        #expect(plugIn.id == PlugInID(rawValue: "com.moonwink.tingra.capture.screencapturekit"))
        #expect(plugIn.name == "ScreenCaptureKit Capture")
    }
}
