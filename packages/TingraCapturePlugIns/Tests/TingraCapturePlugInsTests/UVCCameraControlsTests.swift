//
//  UVCCameraControlsTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization
import Testing
import TingraPlugInKit
import TingraUVC

@testable import TingraCapturePlugIns

/// A UVC camera with no hardware: a configuration descriptor shaped like the
/// Razer Kiyo Pro's and the answers it gave on 2026-10-26 (docs/UVC.md),
/// with `SET_CUR` updating the current value.
private final class RazerTransport: UVCTransport {
    /// Answers by request code, selector, and entity.
    private let answers: Mutex<[String: [UInt8]]>

    /// Creates the scripted Razer.
    init() {
        var answers: [String: [UInt8]] = [:]
        func range(
            _ entity: UInt8, _ selector: UInt8, size: Int, _ low: Int, _ high: Int, res: Int = 1, def: Int, cur: Int,
            info: UInt8 = 0x03
        ) {
            answers[Self.key(.getInfo, selector, entity)] = [info]
            answers[Self.key(.getMinimum, selector, entity)] = Self.bytes(low, size)
            answers[Self.key(.getMaximum, selector, entity)] = Self.bytes(high, size)
            answers[Self.key(.getResolution, selector, entity)] = Self.bytes(res, size)
            answers[Self.key(.getDefault, selector, entity)] = Self.bytes(def, size)
            answers[Self.key(.getCurrent, selector, entity)] = Self.bytes(cur, size)
        }
        func toggle(_ entity: UInt8, _ selector: UInt8, def: Int, cur: Int) {
            answers[Self.key(.getInfo, selector, entity)] = [0x03]
            answers[Self.key(.getDefault, selector, entity)] = [UInt8(def)]
            answers[Self.key(.getCurrent, selector, entity)] = [UInt8(cur)]
        }
        // Processing unit 3.
        range(3, 0x01, size: 2, 0, 1, def: 0, cur: 0)
        range(3, 0x02, size: 2, 0, 255, def: 128, cur: 87)
        range(3, 0x03, size: 2, 0, 255, def: 128, cur: 109)
        range(3, 0x04, size: 2, 0, 255, def: 0, cur: 0, info: 0x0F)
        range(3, 0x05, size: 1, 1, 2, def: 2, cur: 2)
        range(3, 0x07, size: 2, 0, 255, def: 128, cur: 138)
        range(3, 0x08, size: 2, 0, 255, def: 128, cur: 80)
        range(3, 0x0A, size: 2, 2000, 7500, res: 10, def: 5000, cur: 5100)
        toggle(3, 0x0B, def: 1, cur: 0)
        // Camera terminal 1.
        answers[Self.key(.getInfo, 0x02, 1)] = [0x03]
        answers[Self.key(.getResolution, 0x02, 1)] = [0x09]
        answers[Self.key(.getDefault, 0x02, 1)] = [0x08]
        answers[Self.key(.getCurrent, 0x02, 1)] = [0x08]
        toggle(1, 0x03, def: 0, cur: 0)
        range(1, 0x04, size: 4, 3, 2047, def: 156, cur: 963)
        range(1, 0x06, size: 2, 0, 600, def: 0, cur: 0)
        toggle(1, 0x08, def: 1, cur: 1)
        range(1, 0x0B, size: 2, 100, 400, def: 100, cur: 134)
        answers[Self.key(.getInfo, 0x0D, 1)] = [0x03]
        answers[Self.key(.getMinimum, 0x0D, 1)] = Self.bytes(-36000, 4) + Self.bytes(-36000, 4)
        answers[Self.key(.getMaximum, 0x0D, 1)] = Self.bytes(36000, 4) + Self.bytes(36000, 4)
        answers[Self.key(.getResolution, 0x0D, 1)] = Self.bytes(3600, 4) + Self.bytes(3600, 4)
        answers[Self.key(.getDefault, 0x0D, 1)] = Self.bytes(0, 4) + Self.bytes(0, 4)
        answers[Self.key(.getCurrent, 0x0D, 1)] = Self.bytes(0, 4) + Self.bytes(0, 4)
        self.answers = Mutex(answers)
    }

    /// The Razer's configuration descriptor, reduced to the VideoControl
    /// interface: camera terminal 1 advertising `2e 0a 02` and processing
    /// unit 3 advertising `5b 17`.
    static let descriptor: [UInt8] = {
        var bytes: [UInt8] = [9, 0x02, 0, 0, 1, 1, 0, 0x80, 250]
        bytes += [9, 0x04, 0, 0, 1, 0x0E, 0x01, 0, 0]
        bytes += [18, 0x24, 0x02, 1, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0x2E, 0x0A, 0x02]
        bytes += [12, 0x24, 0x05, 3, 1, 0, 0, 2, 0x5B, 0x17, 0, 0]
        bytes[2] = UInt8(bytes.count)
        return bytes
    }()

    /// A raw value's current bytes.
    func current(_ selector: UInt8, entity: UInt8) -> [UInt8]? {
        answers.withLock { $0[Self.key(.getCurrent, selector, entity)] }
    }

    func withConnection<Result>(_ body: (any UVCConnection) throws -> Result) throws -> Result {
        try body(Connection(transport: self))
    }

    /// An answer's key.
    private static func key(_ code: UVCRequestCode, _ selector: UInt8, _ entity: UInt8) -> String {
        "\(code.rawValue)/\(selector)/\(entity)"
    }

    /// A value as little-endian bytes.
    static func bytes(_ value: Int, _ size: Int) -> [UInt8] {
        let raw = UInt64(bitPattern: Int64(value))
        return (0..<size).map { UInt8(truncatingIfNeeded: raw >> (8 * UInt64($0))) }
    }

    /// One scripted connection.
    private struct Connection: UVCConnection {
        /// The transport holding the answers.
        let transport: RazerTransport

        func configurationDescriptor() throws -> [UInt8] { RazerTransport.descriptor }

        func send(_ request: UVCRequest, data: [UInt8]) throws -> [UInt8] {
            try transport.answers.withLock { answers in
                if request.code == .setCurrent {
                    answers[RazerTransport.key(.getCurrent, request.selector, request.entityID)] = data
                    return []
                }
                guard let answer = answers[RazerTransport.key(request.code, request.selector, request.entityID)]
                else { throw UVCError.requestFailed(request, reason: "stalled") }
                return answer
            }
        }
    }
}

/// The Razer's controls as Tingra maps them.
private func razerControls() throws -> (RazerTransport, UVCCameraControls) {
    let transport = RazerTransport()
    let camera = try UVCCamera(name: "Razer Kiyo Pro", transport: transport)
    return (transport, try #require(UVCCameraControls(camera: camera)))
}

@Suite("UVC camera controls")
struct UVCCameraControlsTests {
    @Test("the Razer's controls map to parameters in docs/UVC.md's order and sections")
    func mapsInOrder() throws {
        let (_, controls) = try razerControls()
        #expect(
            controls.parameters.map(\.key) == [
                "exposureAuto", "exposureTime", "gain", "backlightCompensation", "brightness", "contrast",
                "saturation", "sharpness", "whiteBalanceAuto", "whiteBalanceTemperature", "focusAuto", "focus",
                "zoom", "pan", "tilt",
            ])
        #expect(controls.parameters.first?.section == "Exposure")
        #expect(controls.parameters.first { $0.key == "brightness" }?.section == "Image")
        #expect(controls.parameters.first { $0.key == "whiteBalanceTemperature" }?.section == "White Balance")
        #expect(controls.parameters.first { $0.key == "focus" }?.section == "Focus")
        #expect(controls.parameters.last?.section == "Framing")
    }

    @Test("exposure time is in milliseconds on a logarithmic slider, governed by Auto Exposure")
    func mapsExposureTime() throws {
        let (_, controls) = try razerControls()
        let exposure = try #require(controls.parameters.first { $0.key == "exposureTime" })
        #expect(exposure.range == 0.3...204.7)
        #expect(exposure.defaultValue == 15.6)
        #expect(exposure.unit == "ms")
        #expect(exposure.scale == .logarithmic)
        #expect(exposure.automaticToggleKey == "exposureAuto")
        #expect(controls.parameters.first { $0.key == "gain" }?.automaticToggleKey == "exposureAuto")
    }

    @Test("the Auto switches are toggles that govern their values")
    func mapsAutoSwitches() throws {
        let (_, controls) = try razerControls()
        let parameters = controls.parameters
        #expect(parameters.first { $0.key == "exposureAuto" }?.kind == .toggle)
        #expect(parameters.first { $0.key == "whiteBalanceAuto" }?.kind == .toggle)
        #expect(parameters.first { $0.key == "focusAuto" }?.kind == .toggle)
        #expect(parameters.first { $0.key == "whiteBalanceTemperature" }?.automaticToggleKey == "whiteBalanceAuto")
        #expect(parameters.first { $0.key == "focus" }?.automaticToggleKey == "focusAuto")
        #expect(parameters.first { $0.key == "brightness" }?.automaticToggleKey == nil)
    }

    @Test("every number declares the camera's own step, in display units")
    func declaresTheCamerasStep() throws {
        let (_, controls) = try razerControls()
        let steps = Dictionary(uniqueKeysWithValues: controls.parameters.map { ($0.key, $0.step) })
        #expect(steps["brightness"] == 1)
        #expect(steps["whiteBalanceTemperature"] == 10)
        #expect(steps["exposureTime"] == 0.1)
        #expect(steps["pan"] == 1)
        #expect(steps["exposureAuto"] == .some(nil))
    }

    @Test("a control whose range is zero to one becomes a toggle")
    func twoPositionControlsAreToggles() throws {
        let (_, controls) = try razerControls()
        #expect(controls.parameters.first { $0.key == "backlightCompensation" }?.kind == .toggle)
    }

    @Test("pan and tilt are in degrees and a number keeps the camera's own range and default")
    func mapsUnitsAndRanges() throws {
        let (_, controls) = try razerControls()
        #expect(controls.parameters.first { $0.key == "pan" }?.range == -10...10)
        #expect(controls.parameters.first { $0.key == "pan" }?.unit == "°")
        let brightness = try #require(controls.parameters.first { $0.key == "brightness" })
        #expect(brightness.range == 0...255)
        #expect(brightness.defaultValue == 128)
        #expect(brightness.scale == .linear)
        #expect(controls.parameters.first { $0.key == "whiteBalanceTemperature" }?.unit == "K")
    }

    @Test("power line frequency and auto exposure priority are not mapped")
    func leavesChoicesUnmapped() throws {
        let (_, controls) = try razerControls()
        let keys = Set(controls.parameters.map(\.key))
        #expect(!keys.contains("powerLineFrequency"))
        #expect(!keys.contains("autoExposurePriority"))
    }

    @Test("reading converts every raw value to its payload value")
    func readsPayloadValues() throws {
        let (_, controls) = try razerControls()
        let values = try controls.read()
        #expect(values["exposureAuto"] == .bool(true))
        #expect(values["exposureTime"] == .double(96.3))
        #expect(values["brightness"] == .double(87))
        #expect(values["whiteBalanceAuto"] == .bool(false))
        #expect(values["whiteBalanceTemperature"] == .double(5100))
        #expect(values["backlightCompensation"] == .bool(false))
        #expect(values["pan"] == .double(0))
    }

    @Test("a written number is snapped to the control's step")
    func snapsToTheStep() throws {
        let (transport, controls) = try razerControls()
        #expect(controls.write([("whiteBalanceTemperature", .double(6503))]).isEmpty)
        #expect(transport.current(0x0A, entity: 3) == RazerTransport.bytes(6500, 2))
        #expect(controls.write([("exposureTime", .double(10))]).isEmpty)
        #expect(transport.current(0x04, entity: 1) == RazerTransport.bytes(100, 4))
        #expect(controls.write([("pan", .double(2.2))]).isEmpty)
        #expect(transport.current(0x0D, entity: 1) == RazerTransport.bytes(7200, 4) + RazerTransport.bytes(0, 4))
    }

    @Test("Auto Exposure off writes manual, on writes the camera's own automatic mode")
    func writesAutoExposure() throws {
        let (transport, controls) = try razerControls()
        #expect(controls.write([("exposureAuto", .bool(false))]).isEmpty)
        #expect(transport.current(0x02, entity: 1) == [0x01])
        #expect(controls.write([("exposureAuto", .bool(true))]).isEmpty)
        #expect(transport.current(0x02, entity: 1) == [0x08])
    }

    @Test("a toggle writes the control's maximum for on and minimum for off")
    func writesToggles() throws {
        let (transport, controls) = try razerControls()
        #expect(controls.write([("whiteBalanceAuto", .bool(true))]).isEmpty)
        #expect(transport.current(0x0B, entity: 3) == [0x01])
        #expect(controls.write([("backlightCompensation", .bool(true))]).isEmpty)
        #expect(transport.current(0x01, entity: 3) == RazerTransport.bytes(1, 2))
    }

    @Test("a key the controls do not declare is ignored")
    func ignoresUndeclaredKeys() throws {
        let (_, controls) = try razerControls()
        #expect(controls.write([("hue", .double(10))]).isEmpty)
    }

    @Test("a camera with nothing to map has no controls")
    func noMappableControls() throws {
        var bytes: [UInt8] = [9, 0x02, 0, 0, 1, 1, 0, 0x80, 250, 9, 0x04, 0, 0, 1, 0x0E, 0x01, 0, 0]
        bytes[2] = UInt8(bytes.count)
        struct Bare: UVCTransport {
            let descriptor: [UInt8]
            func withConnection<Result>(_ body: (any UVCConnection) throws -> Result) throws -> Result {
                try body(Connection(descriptor: descriptor))
            }
            struct Connection: UVCConnection {
                let descriptor: [UInt8]
                func configurationDescriptor() throws -> [UInt8] { descriptor }
                func send(_ request: UVCRequest, data: [UInt8]) throws -> [UInt8] {
                    throw UVCError.requestFailed(request, reason: "stalled")
                }
            }
        }
        let camera = try UVCCamera(name: "Bare", transport: Bare(descriptor: bytes))
        #expect(UVCCameraControls(camera: camera) == nil)
    }

    @Test("a built-in camera's capture device is not described")
    func builtInCamerasHaveNoControls() throws {
        let device = CaptureDevice(uniqueID: "1FD4B3A2-236E-492B-8CE5-255DD288CE50", name: "FaceTime", kind: .camera)
        #expect(try UVCCameraControls.describe(device) == nil)
        let microphone = CaptureDevice(uniqueID: "0x211100015320e05", name: "Razer Kiyo Pro", kind: .microphone)
        #expect(try UVCCameraControls.describe(microphone) == nil)
    }
}
