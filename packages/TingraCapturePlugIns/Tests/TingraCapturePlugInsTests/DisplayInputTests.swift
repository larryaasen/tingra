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

/// An already-finished change stream, so a plug-in test never installs the
/// real process-wide CoreGraphics reconfiguration callback.
private let noDisplayChanges: @Sendable () -> AsyncStream<DisplayChange> = {
    AsyncStream { $0.finish() }
}

/// A second fixture display, for the diff tests.
private let fixtureExternalDisplay = DisplayDevice(
    uniqueID: "220E3535-0000-0000-271D-0104B53C2278",
    name: "Display 2",
    pixelWidth: 2560,
    pixelHeight: 1440
)

/// A third fixture display, so a diff can report an arrival and a departure
/// in the same reconfiguration.
private let fixtureThirdDisplay = DisplayDevice(
    uniqueID: "5B4F1C90-1111-2222-3333-444455556666",
    name: "Display 3",
    pixelWidth: 1920,
    pixelHeight: 1080
)

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

/// A no-op effect registration seam — the capture plug-in never registers
/// effects.
private struct UnusedEffectRegistrar: EffectRegistering {
    func register(_ provider: any AudioEffectProvider) async throws {}
    func register(_ provider: any VideoEffectProvider) async throws {}
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
        effects: UnusedEffectRegistrar(),
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
        #expect(input.media == .video)
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
        let plugIn = ScreenCaptureKitCapturePlugIn(
            enumerateDisplays: { [fixtureDisplay] }, displayChanges: noDisplayChanges)
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
        let plugIn = ScreenCaptureKitCapturePlugIn(enumerateDisplays: { [] }, displayChanges: noDisplayChanges)
        let registrar = MockDisplayRegistrar()

        try await plugIn.activate(in: makeContext(registrar: registrar))

        #expect(await registrar.registered.isEmpty)
    }

    @Test("each display discovery is reported as a trace event in the capture domain")
    func discoveryEmitsTraceEvents() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let plugIn = ScreenCaptureKitCapturePlugIn(
            enumerateDisplays: { [fixtureDisplay] }, displayChanges: noDisplayChanges)

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
        let plugIn = ScreenCaptureKitCapturePlugIn(
            enumerateDisplays: { [fixtureDisplay] }, displayChanges: noDisplayChanges)
        let registrar = MockDisplayRegistrar(
            rejection: CaptureInputError.deviceUnavailable(InputID(rawValue: "any"))
        )

        await #expect(throws: (any Error).self) {
            try await plugIn.activate(in: makeContext(registrar: registrar))
        }
    }

    @Test("the plug-in carries its stable reverse-DNS identifier")
    func plugInIdentifier() {
        let plugIn = ScreenCaptureKitCapturePlugIn(enumerateDisplays: { [] }, displayChanges: noDisplayChanges)
        #expect(plugIn.id == PlugInID(rawValue: "com.moonwink.tingra.capture.screencapturekit"))
        #expect(plugIn.name == "ScreenCaptureKit Capture")
    }

    @Test("activation begins reporting scripted display changes as bus events")
    func activationReportsDisplayChanges() async throws {
        let eventBus = EventBus()
        let events = eventBus.events()
        let plugIn = ScreenCaptureKitCapturePlugIn(
            enumerateDisplays: { [] },
            displayChanges: {
                AsyncStream { continuation in
                    continuation.yield(DisplayChange(kind: .connected, display: fixtureExternalDisplay))
                    continuation.finish()
                }
            }
        )

        try await plugIn.activate(in: makeContext(registrar: MockDisplayRegistrar(), eventBus: eventBus))
        // The reporter runs in a detached task, like the AVFoundation
        // plug-in's; wait for its event rather than sleeping.
        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
            if event.name == "device.connected" { break }
        }
        eventBus.shutdown()

        let connected = try #require(received.last)
        #expect(connected.name == "device.connected")
        #expect(connected.params?["kind"] == .string("display"))
        #expect(connected.params?["id"] == .string(fixtureExternalDisplay.uniqueID))
    }
}

@Suite("DisplayEventReporter")
struct DisplayEventReporterTests {
    /// A reporter over a scripted change stream, building display inputs like
    /// the plug-in does.
    private func makeReporter(_ changes: [DisplayChange]) -> DisplayEventReporter {
        DisplayEventReporter(
            changes: AsyncStream { continuation in
                for change in changes {
                    continuation.yield(change)
                }
                continuation.finish()
            },
            makeInput: { DisplayInput(display: $0, requestAuthorization: { false }) }
        )
    }

    @Test("display connection and disconnection surface as normal events, never errors")
    func changesBecomeNormalEvents() async {
        let eventBus = EventBus()
        let events = eventBus.events()
        let reporter = makeReporter([
            DisplayChange(kind: .connected, display: fixtureExternalDisplay),
            DisplayChange(kind: .disconnected, display: fixtureExternalDisplay),
        ])

        await reporter.run(on: eventBus, inputs: MockDisplayRegistrar())
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        #expect(received.count == 2)
        #expect(received.map(\.name) == ["device.connected", "device.disconnected"])
        #expect(received.allSatisfy { $0.group == .event })
        // A display coming or going is never a failure (CLAUDE.md, Data Flow
        // Rules) — the same rule the camera/microphone reporter follows.
        #expect(received.allSatisfy { $0.group != .error })
        #expect(received.first?.params?["name"] == .string("Display 2"))
        #expect(received.first?.params?["kind"] == .string("display"))
    }

    @Test("a connection registers the new display input; a disconnection unregisters it")
    func registryStaysCurrent() async {
        let registrar = MockDisplayRegistrar()
        let id = InputID(rawValue: fixtureExternalDisplay.uniqueID)

        await makeReporter([DisplayChange(kind: .connected, display: fixtureExternalDisplay)])
            .run(on: EventBus(), inputs: registrar)
        #expect(await registrar.registered.map(\.id) == [id])

        await makeReporter([DisplayChange(kind: .disconnected, display: fixtureExternalDisplay)])
            .run(on: EventBus(), inputs: registrar)
        #expect(await registrar.registered.isEmpty)
        #expect(await registrar.unregistered == [id])
    }

    @Test("a connection for an already-registered display still reports the event, with a trace, not an error")
    func duplicateConnectionStaysNormal() async {
        let eventBus = EventBus()
        let events = eventBus.events()
        let registrar = MockDisplayRegistrar(
            rejection: CaptureInputError.deviceUnavailable(InputID(rawValue: "dup"))
        )

        await makeReporter([DisplayChange(kind: .connected, display: fixtureExternalDisplay)])
            .run(on: eventBus, inputs: registrar)
        eventBus.shutdown()

        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }
        #expect(received.contains { $0.name == "input.register.skipped" && $0.group == .trace })
        #expect(received.contains { $0.name == "device.connected" && $0.group == .event })
        #expect(!received.contains { $0.group == .error })
    }

    @Test("a diff reports what arrived and what left, connections first")
    func diffReportsBothDirections() {
        let changes = DisplayEventReporter.changes(
            from: [fixtureDisplay, fixtureExternalDisplay],
            to: [fixtureDisplay, fixtureThirdDisplay]
        )

        #expect(changes.count == 2)
        #expect(changes[0] == DisplayChange(kind: .connected, display: fixtureThirdDisplay))
        // The departing display's full identity comes from the snapshot: a
        // removed display's CGDirectDisplayID no longer resolves to a UUID,
        // which is why the reporter diffs instead of reading the callback's
        // argument.
        #expect(changes[1] == DisplayChange(kind: .disconnected, display: fixtureExternalDisplay))
    }

    @Test("an unchanged display set reports nothing")
    func unchangedSetReportsNothing() {
        let displays = [fixtureDisplay, fixtureExternalDisplay]
        #expect(DisplayEventReporter.changes(from: displays, to: displays).isEmpty)
        #expect(DisplayEventReporter.changes(from: [], to: []).isEmpty)
    }

    @Test("a resolution or arrangement change on the same display reports nothing")
    func modeChangeReportsNothing() {
        // CoreGraphics fires the same reconfiguration callback for a mode
        // change, a rotation, and a rearrangement. Identity is the uniqueID
        // alone, so none of those becomes a spurious disconnect/reconnect
        // pair on a display that never left — which would stop and restart a
        // running capture.
        let resized = DisplayDevice(
            uniqueID: fixtureExternalDisplay.uniqueID,
            name: "Display 2",
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        #expect(DisplayEventReporter.changes(from: [fixtureExternalDisplay], to: [resized]).isEmpty)
    }

    @Test("every display leaving reports every one as disconnected")
    func allDisplaysLeaving() {
        let changes = DisplayEventReporter.changes(from: [fixtureDisplay, fixtureExternalDisplay], to: [])
        #expect(changes.count == 2)
        #expect(changes.allSatisfy { $0.kind == .disconnected })
    }
}
