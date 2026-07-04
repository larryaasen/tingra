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

    /// The identifiers unregistered so far, in order.
    private(set) var unregistered: [InputID] = []

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
        unregistered.append(id)
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

/// The fixture devices the injected enumerator returns — the CLI.md example
/// hardware, no camera or TCC needed.
private let fixtureDevices = [
    CaptureDevice(uniqueID: "0x8020000005ac8514", name: "FaceTime HD Camera", kind: .camera),
    CaptureDevice(uniqueID: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", kind: .microphone),
]

/// An already-finished change stream for tests not exercising device events.
private let noChanges: @Sendable () -> AsyncStream<DeviceChange> = {
    AsyncStream { $0.finish() }
}

/// Builds a context over a fresh bus and mock registrar.
private func makeContext(registrar: MockInputRegistrar, eventBus: EventBus = EventBus()) -> PlugInContext {
    PlugInContext(eventBus: eventBus, clock: SyntheticClock(), inputs: registrar)
}

@Suite("AVFoundationCapturePlugIn")
struct AVFoundationCapturePlugInTests {
    @Test("activation registers one input per discovered device, preserving identifier, name, and kind")
    func activationRegistersDiscoveredDevices() async throws {
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { fixtureDevices }, deviceChanges: noChanges)
        let registrar = MockInputRegistrar()

        try await plugIn.activate(in: makeContext(registrar: registrar))

        let registered = await registrar.registered
        try #require(registered.count == 2)
        #expect(registered[0].id == InputID(rawValue: "0x8020000005ac8514"))
        #expect(registered[0].name == "FaceTime HD Camera")
        #expect(registered[0].kind == .camera)
        #expect(registered[0] is CameraInput)
        #expect(registered[1].id == InputID(rawValue: "BuiltInMicrophoneDevice"))
        #expect(registered[1].name == "MacBook Pro Microphone")
        #expect(registered[1].kind == .microphone)
        #expect(registered[1] is MicrophoneInput)
    }

    @Test("activation with no connected devices registers nothing")
    func activationWithNoDevices() async throws {
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { [] }, deviceChanges: noChanges)
        let registrar = MockInputRegistrar()

        try await plugIn.activate(in: makeContext(registrar: registrar))

        #expect(await registrar.registered.isEmpty)
    }

    @Test("a registry rejection propagates out of activation")
    func registryRejectionPropagates() async {
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { fixtureDevices }, deviceChanges: noChanges)
        let registrar = MockInputRegistrar(
            rejection: CaptureInputError.deviceUnavailable(InputID(rawValue: "any"))
        )

        await #expect(throws: (any Error).self) {
            try await plugIn.activate(in: makeContext(registrar: registrar))
        }
    }

    @Test("each discovery is reported as a trace event on the bus")
    func discoveryEmitsTraceEvents() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { fixtureDevices }, deviceChanges: noChanges)

        try await plugIn.activate(in: makeContext(registrar: MockInputRegistrar(), eventBus: eventBus))
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        let discoveries = received.filter { $0.name == "input.discovered" }
        #expect(discoveries.count == 2)
        #expect(discoveries.allSatisfy { $0.group == .trace && $0.domain == .capture })
        #expect(discoveries.first?.params?["id"] == .string("0x8020000005ac8514"))
        #expect(discoveries.first?.params?["kind"] == .string("camera"))
    }

    @Test("activation begins reporting scripted device changes as bus events")
    func activationReportsDeviceChanges() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let changes: [DeviceChange] = [
            DeviceChange(kind: .connected, device: fixtureDevices[0]),
            DeviceChange(kind: .disconnected, device: fixtureDevices[0]),
        ]
        let plugIn = AVFoundationCapturePlugIn(
            enumerateDevices: { [] },
            deviceChanges: {
                AsyncStream { continuation in
                    for change in changes {
                        continuation.yield(change)
                    }
                    continuation.finish()
                }
            }
        )

        try await plugIn.activate(in: makeContext(registrar: MockInputRegistrar(), eventBus: eventBus))

        // The reporter runs as its own task; await exactly the two device
        // events it must emit (the subscription buffers, so no timing games).
        var received: [EventBusEvent] = []
        for await event in events where event.name.hasPrefix("device.") {
            received.append(event)
            if received.count == 2 { break }
        }
        #expect(received[0].name == "device.connected")
        #expect(received[1].name == "device.disconnected")
        #expect(received.allSatisfy { $0.group == .event && $0.domain == .capture })
        #expect(received[0].params?["id"] == .string("0x8020000005ac8514"))
        #expect(received[0].params?["kind"] == .string("camera"))
    }

    @Test("the plug-in carries its stable reverse-DNS identifier")
    func plugInIdentifier() {
        let plugIn = AVFoundationCapturePlugIn(enumerateDevices: { [] }, deviceChanges: noChanges)
        #expect(plugIn.id == PlugInID(rawValue: "com.moonwink.tingra.capture.avfoundation"))
        #expect(plugIn.name == "AVFoundation Capture")
    }
}

@Suite("DeviceEventReporter")
struct DeviceEventReporterTests {
    /// A reporter over a scripted change stream, building microphone
    /// inputs like the plug-in does.
    private func makeReporter(_ changes: [DeviceChange]) -> DeviceEventReporter {
        DeviceEventReporter(
            changes: AsyncStream { continuation in
                for change in changes {
                    continuation.yield(change)
                }
                continuation.finish()
            },
            makeInput: { MicrophoneInput(device: $0, requestAuthorization: { false }) }
        )
    }

    @Test("device connection and disconnection surface as normal events, never errors")
    func changesBecomeNormalEvents() async {
        let eventBus = EventBus()
        let events = eventBus.events()
        let device = fixtureDevices[1]
        let reporter = makeReporter([
            DeviceChange(kind: .connected, device: device),
            DeviceChange(kind: .disconnected, device: device),
        ])

        await reporter.run(on: eventBus, inputs: MockInputRegistrar())
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        #expect(received.count == 2)
        #expect(received.map(\.name) == ["device.connected", "device.disconnected"])
        #expect(received.allSatisfy { $0.group == .event })
        #expect(received.allSatisfy { $0.group != .error })
        #expect(received.first?.params?["name"] == .string("MacBook Pro Microphone"))
        #expect(received.first?.params?["kind"] == .string("microphone"))
    }

    @Test("a connection registers the new input; a disconnection unregisters it")
    func registryStaysCurrent() async {
        let device = fixtureDevices[1]
        let registrar = MockInputRegistrar()

        await makeReporter([DeviceChange(kind: .connected, device: device)])
            .run(on: EventBus(), inputs: registrar)
        let afterConnect = await registrar.registered
        #expect(afterConnect.map(\.id) == [InputID(rawValue: device.uniqueID)])

        await makeReporter([DeviceChange(kind: .disconnected, device: device)])
            .run(on: EventBus(), inputs: registrar)
        #expect(await registrar.registered.isEmpty)
        #expect(await registrar.unregistered == [InputID(rawValue: device.uniqueID)])
    }

    @Test("a connection for an already-registered device still reports the event, with a trace, not an error")
    func duplicateConnectionStaysNormal() async {
        let eventBus = EventBus()
        let events = eventBus.events()
        let device = fixtureDevices[1]
        let registrar = MockInputRegistrar(rejection: CaptureInputError.deviceUnavailable(InputID(rawValue: "dup")))

        await makeReporter([DeviceChange(kind: .connected, device: device)])
            .run(on: eventBus, inputs: registrar)
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        #expect(received.map(\.name) == ["input.register.skipped", "device.connected"])
        #expect(received.allSatisfy { $0.group != .error })
    }
}
