//
//  CameraParametersTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraCapturePlugIns

/// A camera's controls with no camera behind them: fixed parameters, values
/// held in memory, writes recorded, and scripted rejections.
final class ScriptedCameraControls: CameraControls {
    /// The mutable camera state behind the mutex.
    private struct State {
        /// The values the "camera" holds.
        var values: [String: JSONValue]
        /// Every write batch, in order.
        var writes: [[String]] = []
        /// Whether reads throw, as an unplugged camera's do.
        var isUnreachable = false
        /// The keys the camera rejects.
        var rejectedKeys: Set<String> = []
    }

    /// The parameters declared.
    let parameters: [Parameter]

    /// The state.
    private let state: Mutex<State>

    /// Creates scripted controls.
    ///
    /// - Parameters:
    ///   - parameters: The parameters to declare.
    ///   - values: The values the camera holds.
    init(parameters: [Parameter], values: [String: JSONValue]) {
        self.parameters = parameters
        self.state = Mutex(State(values: values))
    }

    /// The camera's values now.
    var values: [String: JSONValue] { state.withLock { $0.values } }

    /// The keys of each write batch, in order.
    var writes: [[String]] { state.withLock { $0.writes } }

    /// Makes reads and writes throw, or work again.
    func setUnreachable(_ isUnreachable: Bool) {
        state.withLock { $0.isUnreachable = isUnreachable }
    }

    /// Makes the camera reject a key.
    func reject(_ key: String) {
        state.withLock { _ = $0.rejectedKeys.insert(key) }
    }

    /// Changes a value behind the input's back, as the camera's own
    /// automatic mode does.
    func drift(_ key: String, to value: JSONValue) {
        state.withLock { $0.values[key] = value }
    }

    func read() throws -> [String: JSONValue] {
        try state.withLock { state in
            guard !state.isUnreachable else { throw CameraControlFailure(key: "", reason: "unplugged") }
            return state.values
        }
    }

    func write(_ values: [(key: String, value: JSONValue)]) -> [CameraControlFailure] {
        state.withLock { state in
            state.writes.append(values.map(\.key))
            guard !state.isUnreachable else {
                return values.map { CameraControlFailure(key: $0.key, reason: "unplugged") }
            }
            var failures: [CameraControlFailure] = []
            for (key, value) in values {
                if state.rejectedKeys.contains(key) {
                    failures.append(CameraControlFailure(key: key, reason: "stalled"))
                } else {
                    state.values[key] = value
                }
            }
            return failures
        }
    }

    /// A camera shaped like the Razer: auto exposure with a governed
    /// exposure time, brightness, and auto white balance with a governed
    /// temperature.
    static func razerLike() -> ScriptedCameraControls {
        ScriptedCameraControls(
            parameters: [
                Parameter(key: "exposureAuto", name: "Auto Exposure", defaultIsOn: true).inSection("Exposure"),
                Parameter(
                    key: "exposureTime", name: "Exposure Time", range: 0.3...204.7, defaultValue: 15.6, unit: "ms",
                    scale: .logarithmic
                ).inSection("Exposure").controlledAutomatically(whenOn: "exposureAuto"),
                Parameter(key: "brightness", name: "Brightness", range: 0...255, defaultValue: 128)
                    .inSection("Image"),
                Parameter(key: "whiteBalanceAuto", name: "Auto White Balance", defaultIsOn: true)
                    .inSection("White Balance"),
                Parameter(key: "whiteBalanceTemperature", name: "Temperature", range: 2000...7500, defaultValue: 5000)
                    .inSection("White Balance").controlledAutomatically(whenOn: "whiteBalanceAuto"),
            ],
            values: [
                "exposureAuto": .bool(true),
                "exposureTime": .double(96.3),
                "brightness": .double(87),
                "whiteBalanceAuto": .bool(false),
                "whiteBalanceTemperature": .double(5101),
            ]
        )
    }
}

/// A camera with the given controls, never started.
private func camera(_ controls: ScriptedCameraControls?, eventBus: EventBus? = nil) -> CameraInput {
    CameraInput(
        device: CaptureDevice(uniqueID: "0x211100015320e05", name: "Razer Kiyo Pro", kind: .camera),
        eventBus: eventBus,
        requestAuthorization: { false },
        controls: controls
    )
}

/// Drains a shut-down bus's events.
private func drain(_ events: AsyncStream<EventBusEvent>) async -> [EventBusEvent] {
    var received: [EventBusEvent] = []
    for await event in events {
        received.append(event)
    }
    return received
}

@Suite("Camera parameters")
struct CameraParametersTests {
    @Test("a camera with no controls declares no parameters and reports none of its own")
    func cameraWithoutControls() async {
        let input = camera(nil)
        #expect(input.parameters.isEmpty)
        #expect(await input.currentParameters().isEmpty)
        await input.setParameters(["brightness": .double(10)])
    }

    @Test("a camera declares its controls' parameters in their order")
    func declaresTheControlsParameters() {
        let controls = ScriptedCameraControls.razerLike()
        #expect(camera(controls).parameters == controls.parameters)
    }

    @Test("currentParameters reads the camera's own values")
    func readsTheCamerasValues() async {
        let controls = ScriptedCameraControls.razerLike()
        #expect(await camera(controls).currentParameters() == controls.values)
    }

    @Test("applying the values just read writes nothing")
    func applyingCurrentValuesWritesNothing() async {
        let controls = ScriptedCameraControls.razerLike()
        let input = camera(controls)
        let current = await input.currentParameters()
        await input.setParameters(current)
        #expect(controls.writes.isEmpty)
    }

    @Test("only the changed value is written")
    func writesOnlyWhatChanged() async {
        let controls = ScriptedCameraControls.razerLike()
        let input = camera(controls)
        var payload = await input.currentParameters()
        payload["brightness"] = .double(120)
        await input.setParameters(payload)
        #expect(controls.writes == [["brightness"]])
        #expect(controls.values["brightness"] == .double(120))
        await input.setParameters(payload)
        #expect(controls.writes == [["brightness"]])
    }

    @Test("a value is clamped into its range before it is written")
    func clampsBeforeWriting() async {
        let controls = ScriptedCameraControls.razerLike()
        let input = camera(controls)
        var payload = await input.currentParameters()
        payload["brightness"] = .double(900)
        await input.setParameters(payload)
        #expect(controls.values["brightness"] == .double(255))
    }

    @Test("a value between steps is snapped to the parameter's step before it is written")
    func snapsBeforeWriting() async {
        let pan = Parameter(key: "pan", name: "Pan", range: -10...10, defaultValue: 0).stepped(by: 1)
        let controls = ScriptedCameraControls(parameters: [pan], values: ["pan": .double(0)])
        let input = camera(controls)
        _ = await input.currentParameters()
        await input.setParameters(["pan": .double(-0.003)])
        #expect(controls.writes.isEmpty)
        await input.setParameters(["pan": .double(2.6)])
        #expect(controls.values["pan"] == .double(3))
    }

    @Test("a value whose Auto toggle is on is never written")
    func skipsGovernedValues() async {
        let controls = ScriptedCameraControls.razerLike()
        let input = camera(controls)
        var payload = await input.currentParameters()
        payload["exposureTime"] = .double(10)
        await input.setParameters(payload)
        #expect(controls.writes.isEmpty)
        #expect(controls.values["exposureTime"] == .double(96.3))
    }

    @Test("turning Auto off writes the toggle before the value it releases")
    func writesTogglesFirst() async {
        let controls = ScriptedCameraControls.razerLike()
        let input = camera(controls)
        var payload = await input.currentParameters()
        payload["exposureTime"] = .double(10)
        payload["exposureAuto"] = .bool(false)
        await input.setParameters(payload)
        #expect(controls.writes == [["exposureAuto", "exposureTime"]])
    }

    @Test("an empty payload restores the declared defaults, per the seam's contract")
    func emptyPayloadRestoresDefaults() async {
        let controls = ScriptedCameraControls.razerLike()
        let input = camera(controls)
        _ = await input.currentParameters()
        await input.setParameters([:])
        #expect(controls.values["brightness"] == .double(128))
        #expect(controls.values["whiteBalanceAuto"] == .bool(true))
        // White balance is back on Auto, so the temperature is left alone.
        #expect(controls.values["whiteBalanceTemperature"] == .double(5101))
    }

    @Test("a fresh read picks up a value the camera changed on its own")
    func rereadsAfterDrift() async {
        let controls = ScriptedCameraControls.razerLike()
        let input = camera(controls)
        _ = await input.currentParameters()
        controls.drift("exposureTime", to: .double(40))
        #expect(await input.currentParameters()["exposureTime"] == .double(40))
    }

    @Test("a value the camera rejects is reported and the rest still apply")
    func reportsRejectedValues() async {
        let eventBus = EventBus()
        let events = eventBus.events()
        let controls = ScriptedCameraControls.razerLike()
        controls.reject("brightness")
        let input = camera(controls, eventBus: eventBus)
        var payload = await input.currentParameters()
        payload["brightness"] = .double(120)
        payload["whiteBalanceTemperature"] = .double(6500)
        await input.setParameters(payload)
        eventBus.shutdown()

        #expect(controls.values["whiteBalanceTemperature"] == .double(6500))
        #expect(controls.values["brightness"] == .double(87))
        let errors = await drain(events).filter { $0.name == "input.parameterSet" }
        #expect(errors.count == 1)
        #expect(errors.first?.group == .error)
        #expect(errors.first?.params?["key"] == .string("brightness"))
        #expect(errors.first?.params?["error"] == .string("stalled"))
    }

    @Test("a rejected value is tried again on the next apply")
    func retriesARejectedValue() async {
        let controls = ScriptedCameraControls.razerLike()
        controls.reject("brightness")
        let input = camera(controls)
        var payload = await input.currentParameters()
        payload["brightness"] = .double(120)
        await input.setParameters(payload)
        await input.setParameters(payload)
        #expect(controls.writes == [["brightness"], ["brightness"]])
    }

    @Test("an unreachable camera reports the read and returns the values it last held")
    func unreachableReadReturnsLastKnown() async {
        let eventBus = EventBus()
        let events = eventBus.events()
        let controls = ScriptedCameraControls.razerLike()
        let input = camera(controls, eventBus: eventBus)
        let before = await input.currentParameters()
        controls.setUnreachable(true)
        let after = await input.currentParameters()
        eventBus.shutdown()

        #expect(after == before)
        let errors = await drain(events).filter { $0.name == "input.parameterRead" }
        #expect(errors.count == 1)
        #expect(errors.first?.params?["id"] == .string("0x211100015320e05"))
    }

    @Test("the plan resolves every toggle and number, defaulting omitted keys")
    func resolvesAPayload() {
        let parameters = ScriptedCameraControls.razerLike().parameters
        let resolved = CameraParameterPlan.resolved(["brightness": .int(40)], parameters: parameters)
        #expect(resolved["brightness"] == .double(40))
        #expect(resolved["exposureAuto"] == .bool(true))
        #expect(resolved["whiteBalanceTemperature"] == .double(5000))
        #expect(resolved.count == parameters.count)
    }
}
