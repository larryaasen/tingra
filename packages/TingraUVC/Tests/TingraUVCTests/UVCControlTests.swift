//
//  UVCControlTests.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraUVC

/// Reading and setting a described control.
@Suite("UVC control")
struct UVCControlTests {
    @Test("value reads the camera's current setting")
    func readsTheCurrentValue() throws {
        let (_, camera) = try CameraFixture.razer()
        #expect(try camera.brightness?.value() == 87)
        #expect(try camera.exposureTime?.value() == 963)
        #expect(try camera.pan?.value() == 7200)
        #expect(try camera.tilt?.value() == -3600)
    }

    @Test("setValue sends SET_CUR to the control's entity, little-endian")
    func writesLittleEndian() throws {
        let (transport, camera) = try CameraFixture.razer()
        try camera.whiteBalanceTemperature?.setValue(6500)
        let request = try #require(transport.sentRequests.last)
        #expect(request.code == .setCurrent)
        #expect(request.selector == 0x0A)
        #expect(request.entityID == 3)
        #expect(request.interfaceNumber == 0)
        #expect(request.length == 2)
        #expect(transport.writes == [[0x64, 0x19]])
        #expect(try camera.whiteBalanceTemperature?.value() == 6500)
    }

    @Test("each plain call opens its own exchange")
    func opensAnExchangePerCall() throws {
        let (transport, camera) = try CameraFixture.razer()
        _ = try camera.brightness?.value()
        try camera.brightness?.setValue(90)
        #expect(transport.connectionCount == 3)
    }

    @Test("several calls share one exchange through withConnection")
    func sharesAnExchange() throws {
        let (transport, camera) = try CameraFixture.razer()
        let brightness = try #require(camera.brightness)
        let contrast = try #require(camera.contrast)
        try camera.withConnection { connection in
            try brightness.setValue(100, on: connection)
            try contrast.setValue(120, on: connection)
        }
        #expect(transport.connectionCount == 2)
        #expect(transport.writes == [[100, 0], [120, 0]])
    }

    @Test("a value outside the range throws valueOutOfRange and sends nothing")
    func rejectsOutOfRange() throws {
        let (transport, camera) = try CameraFixture.razer()
        let sentBefore = transport.sentRequests.count
        #expect(throws: UVCError.valueOutOfRange(.brightness, value: 256, range: 0...255)) {
            try camera.brightness?.setValue(256)
        }
        #expect(transport.sentRequests.count == sentBefore)
    }

    @Test("power line frequency starts at zero whatever GET_MIN says, and stops at GET_MAX")
    func powerLineFrequencyOptions() throws {
        var answers = CameraFixture.razerAnswers()
        answers.merge(
            CameraFixture.rangeAnswers(
                { CameraFixture.processing($0, 0x05) }, size: 1, range: 1...2, defaultValue: 2, current: 2)
        ) { $1 }
        let transport = ScriptedTransport(descriptor: CameraFixture.descriptor(), answers: answers)
        let camera = try UVCCamera(name: "Razer Kiyo Pro", transport: transport)
        let frequency = try #require(camera.powerLineFrequency)
        #expect(frequency.range == 0...2)
        #expect(frequency.defaultValue == 2)
        try frequency.setValue(0)
        #expect(transport.writes == [[0x00]])
        #expect(throws: UVCError.self) { try frequency.setValue(3) }
        #expect(transport.writes == [[0x00]])
    }

    @Test("a switch takes only zero or one")
    func rejectsANonBooleanSwitchValue() throws {
        let (_, camera) = try CameraFixture.razer()
        #expect(throws: UVCError.valueOutOfRange(.whiteBalanceTemperatureAuto, value: 2, range: 0...1)) {
            try camera.whiteBalanceTemperatureAuto?.setValue(2)
        }
        try camera.whiteBalanceTemperatureAuto?.setValue(1)
        #expect(try camera.whiteBalanceTemperatureAuto?.value() == 1)
    }

    @Test("the auto exposure mode takes exactly one supported mode")
    func validatesTheAutoExposureMode() throws {
        let (_, camera) = try CameraFixture.razer()
        let supported: UVCAutoExposureMode = [.manual, .aperturePriority]
        #expect(throws: UVCError.unsupportedAutoExposureMode(2, supported: supported)) {
            try camera.autoExposureMode?.setValue(Int(UVCAutoExposureMode.auto.rawValue))
        }
        #expect(throws: UVCError.unsupportedAutoExposureMode(9, supported: supported)) {
            try camera.autoExposureMode?.setValue(9)
        }
        #expect(throws: UVCError.unsupportedAutoExposureMode(0, supported: supported)) {
            try camera.autoExposureMode?.setValue(0)
        }
        try camera.autoExposureMode?.setValue(Int(UVCAutoExposureMode.manual.rawValue))
        #expect(try camera.autoExposureMode?.value() == 1)
    }

    @Test("setting pan writes tilt back unchanged")
    func preservesTiltWhenSettingPan() throws {
        let (transport, camera) = try CameraFixture.razer()
        try camera.pan?.setValue(-7200)
        #expect(transport.writes == [CameraFixture.bytes(-7200, size: 4) + CameraFixture.bytes(-3600, size: 4)])
        #expect(try camera.tilt?.value() == -3600)
    }

    @Test("setting tilt writes pan back unchanged")
    func preservesPanWhenSettingTilt() throws {
        let (transport, camera) = try CameraFixture.razer()
        try camera.tilt?.setValue(3600)
        #expect(transport.writes == [CameraFixture.bytes(7200, size: 4) + CameraFixture.bytes(3600, size: 4)])
    }

    @Test("a read-only control throws controlNotSettable")
    func rejectsWritesToReadOnlyControls() throws {
        var answers = CameraFixture.razerAnswers()
        answers[CameraFixture.processing(.getInfo, 0x02)] = [0x01]
        let camera = try UVCCamera(
            name: "Razer Kiyo Pro",
            transport: ScriptedTransport(descriptor: CameraFixture.descriptor(), answers: answers)
        )
        #expect(throws: UVCError.controlNotSettable(.brightness)) {
            try camera.brightness?.setValue(100)
        }
    }

    @Test("a rejected request surfaces as requestFailed")
    func reportsARejectedRequest() throws {
        let (_, camera) = try CameraFixture.razer()
        // The fixture answers no GET_CUR for auto exposure priority's
        // selector; reading the mode's neighbor through a stalled selector
        // is what a rejected request looks like.
        let request = UVCRequest(code: .getCurrent, selector: 0x03, entityID: 1, interfaceNumber: 0, length: 1)
        #expect(throws: UVCError.requestFailed(request, reason: "stalled")) {
            try camera.withConnection { try $0.send(request, data: []) }
        }
    }

    @Test("an answer too short for the value surfaces as shortResponse")
    func reportsAShortAnswer() throws {
        let (transport, camera) = try CameraFixture.razer()
        let zoom = try #require(camera.zoom)
        transport.answer([], for: CameraFixture.camera(.getCurrent, 0x0B))
        #expect {
            try zoom.value()
        } throws: { error in
            guard case UVCError.shortResponse(let request, received: 0) = error else { return false }
            return request.code == .getCurrent && request.selector == 0x0B
        }
    }

    @Test("isDisabledByAutomaticMode reads the live GET_INFO bit")
    func readsTheAutomaticModeBit() throws {
        let (transport, camera) = try CameraFixture.razer()
        let temperature = try #require(camera.whiteBalanceTemperature)
        #expect(try temperature.isDisabledByAutomaticMode() == false)
        transport.answer([0x07], for: CameraFixture.processing(.getInfo, 0x0A))
        #expect(try temperature.isDisabledByAutomaticMode() == true)
    }

    @Test("a signed control reads a negative value")
    func readsNegativeValues() throws {
        let (transport, camera) = try CameraFixture.razer()
        transport.answer(CameraFixture.bytes(-10, size: 2), for: CameraFixture.processing(.getCurrent, 0x02))
        #expect(try camera.brightness?.value() == -10)
    }
}
