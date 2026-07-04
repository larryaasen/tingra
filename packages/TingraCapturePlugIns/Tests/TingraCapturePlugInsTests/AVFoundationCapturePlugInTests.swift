//
//  AVFoundationCapturePlugInTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraCapturePlugIns

/// Collects registered inputs, standing in for the host's registry —
/// no engine dependency, per the package's seam-only design.
private actor MockInputRegistrar: InputRegistering {
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
}

/// A fixed synthetic clock, per CLOCK.md's test substitution rule.
private struct SyntheticClock: EngineClock {
    var now: CMTime { .zero }

    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { $0.finish() }
    }
}

/// The fixture devices the injected enumerator returns — the CLI.md example
/// hardware, no camera or TCC needed.
private let fixtureDevices = [
    CaptureDevice(uniqueID: "0x8020000005ac8514", name: "FaceTime HD Camera", kind: .camera),
    CaptureDevice(uniqueID: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", kind: .microphone),
]

/// Builds a context over a fresh bus and mock registrar.
private func makeContext(registrar: MockInputRegistrar, eventBus: EventBus = EventBus()) -> PlugInContext {
    PlugInContext(eventBus: eventBus, clock: SyntheticClock(), inputs: registrar)
}

@Suite("AVFoundationCapturePlugIn")
struct AVFoundationCapturePlugInTests {
    @Test("activation registers one input per discovered device, preserving identifier, name, and kind")
    func activationRegistersDiscoveredDevices() async throws {
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { fixtureDevices })
        let registrar = MockInputRegistrar()

        try await plugIn.activate(in: makeContext(registrar: registrar))

        let registered = await registrar.registered
        try #require(registered.count == 2)
        #expect(registered[0].id == InputID(rawValue: "0x8020000005ac8514"))
        #expect(registered[0].name == "FaceTime HD Camera")
        #expect(registered[0].kind == .camera)
        #expect(registered[1].id == InputID(rawValue: "BuiltInMicrophoneDevice"))
        #expect(registered[1].name == "MacBook Pro Microphone")
        #expect(registered[1].kind == .microphone)
    }

    @Test("activation with no connected devices registers nothing")
    func activationWithNoDevices() async throws {
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { [] })
        let registrar = MockInputRegistrar()

        try await plugIn.activate(in: makeContext(registrar: registrar))

        #expect(await registrar.registered.isEmpty)
    }

    @Test("a registry rejection propagates out of activation")
    func registryRejectionPropagates() async {
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { fixtureDevices })
        let registrar = MockInputRegistrar(rejection: CaptureInputError.captureNotImplemented(InputID(rawValue: "any")))

        await #expect(throws: (any Error).self) {
            try await plugIn.activate(in: makeContext(registrar: registrar))
        }
    }

    @Test("each discovery is reported as a trace event on the bus")
    func discoveryEmitsTraceEvents() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { fixtureDevices })

        try await plugIn.activate(in: makeContext(registrar: MockInputRegistrar(), eventBus: eventBus))
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        #expect(received.count == 2)
        #expect(received.allSatisfy { $0.group == .trace && $0.domain == .capture && $0.name == "input.discovered" })
        #expect(received.first?.params?["id"] == .string("0x8020000005ac8514"))
        #expect(received.first?.params?["kind"] == .string("camera"))
    }

    @Test("the plug-in carries its stable reverse-DNS identifier")
    func plugInIdentifier() {
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { [] })
        #expect(plugIn.id == PlugInID(rawValue: "com.moonwink.tingra.capture.avfoundation"))
        #expect(plugIn.name == "AVFoundation Capture")
    }
}

@Suite("CaptureDeviceInput")
struct CaptureDeviceInputTests {
    @Test("start() throws a descriptive error while the input is discovery-only")
    func startThrowsWhileDiscoveryOnly() async {
        let input = CaptureDeviceInput(device: fixtureDevices[0])

        await #expect(throws: CaptureInputError.captureNotImplemented(input.id)) {
            try await input.start()
        }
    }

    @Test("frames() finishes immediately while the input is discovery-only")
    func framesFinishImmediately() async {
        let input = CaptureDeviceInput(device: fixtureDevices[0])

        var count = 0
        for await _ in input.frames() {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("the capture-not-implemented description names the input and the fix")
    func errorDescriptionIsDeveloperFacing() {
        let description = String(describing: CaptureInputError.captureNotImplemented(InputID(rawValue: "0x1")))
        #expect(description.contains("0x1"))
        #expect(description.contains("roadmap step 2"))
    }
}
