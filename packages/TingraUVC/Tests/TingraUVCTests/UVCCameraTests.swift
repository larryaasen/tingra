//
//  UVCCameraTests.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraUVC

/// Describing a camera: which controls it gets, and what each reports.
@Suite("UVC camera")
struct UVCCameraTests {
    @Test("a camera lists the advertised controls it could describe, in catalog order")
    func listsDescribedControls() throws {
        let (_, camera) = try CameraFixture.razer()
        #expect(
            camera.controls.map(\.kind) == [
                .autoExposureMode, .exposureTime, .brightness, .contrast, .whiteBalanceTemperatureAuto,
                .whiteBalanceTemperature, .zoom, .pan, .tilt,
            ])
    }

    @Test("describing a camera opens it once")
    func describesInOneExchange() throws {
        let (transport, _) = try CameraFixture.razer()
        #expect(transport.connectionCount == 1)
    }

    @Test("an unadvertised control is absent even when the camera would answer for it")
    func omitsUnadvertisedControls() throws {
        var answers = CameraFixture.razerAnswers()
        answers.merge(
            CameraFixture.rangeAnswers(
                { CameraFixture.processing($0, 0x06) }, size: 2, range: -180...180, defaultValue: 0, current: 0)
        ) { $1 }
        let camera = try UVCCamera(
            name: "Razer Kiyo Pro",
            transport: ScriptedTransport(descriptor: CameraFixture.descriptor(), answers: answers)
        )
        #expect(camera.hue == nil)
        #expect(camera.control(.hue) == nil)
    }

    @Test("a range control reports the camera's minimum, maximum, step, and default")
    func describesARange() throws {
        let (_, camera) = try CameraFixture.razer()
        let temperature = try #require(camera.whiteBalanceTemperature)
        #expect(temperature.minimum == 2000)
        #expect(temperature.maximum == 7500)
        #expect(temperature.range == 2000...7500)
        #expect(temperature.resolution == 1)
        #expect(temperature.defaultValue == 5000)
        #expect(temperature.capabilities == [.supportsGet, .supportsSet])
    }

    @Test("a switch spans zero to one and keeps the camera's default")
    func describesASwitch() throws {
        let (_, camera) = try CameraFixture.razer()
        let auto = try #require(camera.whiteBalanceTemperatureAuto)
        #expect(auto.range == 0...1)
        #expect(auto.defaultValue == 1)
    }

    @Test("the auto exposure mode reports its supported modes and spans them")
    func describesTheAutoExposureBitmap() throws {
        let (_, camera) = try CameraFixture.razer()
        let mode = try #require(camera.autoExposureMode)
        #expect(mode.supportedAutoExposureModes == [.manual, .aperturePriority])
        #expect(mode.minimum == 1)
        #expect(mode.maximum == 8)
        #expect(mode.defaultValue == 8)
        #expect(camera.brightness?.supportedAutoExposureModes == nil)
    }

    @Test("pan and tilt each read their own half of the shared control's range")
    func describesPanAndTilt() throws {
        let (_, camera) = try CameraFixture.razer()
        #expect(camera.pan?.range == -36000...36000)
        #expect(camera.tilt?.range == -36000...36000)
        #expect(camera.tilt?.resolution == 3600)
    }

    @Test("a control whose range requests stall is left out")
    func omitsAControlThatCannotBeDescribed() throws {
        var answers = CameraFixture.razerAnswers()
        answers[CameraFixture.processing(.getMaximum, 0x03)] = nil
        let camera = try UVCCamera(
            name: "Razer Kiyo Pro",
            transport: ScriptedTransport(descriptor: CameraFixture.descriptor(), answers: answers)
        )
        #expect(camera.contrast == nil)
        #expect(camera.brightness != nil)
    }

    @Test("a missing step reads as one and a missing default as the minimum")
    func fillsMissingStepAndDefault() throws {
        var answers = CameraFixture.razerAnswers()
        answers[CameraFixture.processing(.getResolution, 0x02)] = nil
        answers[CameraFixture.processing(.getDefault, 0x02)] = nil
        let camera = try UVCCamera(
            name: "Razer Kiyo Pro",
            transport: ScriptedTransport(descriptor: CameraFixture.descriptor(), answers: answers)
        )
        let brightness = try #require(camera.brightness)
        #expect(brightness.resolution == 1)
        #expect(brightness.defaultValue == 0)
    }

    @Test("a control that does not answer GET_INFO is taken to support get and set")
    func assumesGetAndSetWithoutInfo() throws {
        var answers = CameraFixture.razerAnswers()
        answers[CameraFixture.processing(.getInfo, 0x02)] = nil
        let camera = try UVCCamera(
            name: "Razer Kiyo Pro",
            transport: ScriptedTransport(descriptor: CameraFixture.descriptor(), answers: answers)
        )
        #expect(camera.brightness?.capabilities == [.supportsGet, .supportsSet])
    }

    @Test("a device that is not a UVC camera throws noVideoControlInterface")
    func throwsForANonCamera() {
        let audioOnly: [UInt8] = [9, 0x02, 18, 0, 1, 1, 0, 0x80, 250, 9, 0x04, 0, 0, 0, 0x01, 0x01, 0, 0]
        #expect(throws: UVCError.noVideoControlInterface(name: "Speaker")) {
            try UVCCamera(name: "Speaker", transport: ScriptedTransport(descriptor: audioOnly))
        }
    }

    @Test("a camera keeps its name")
    func keepsItsName() throws {
        let (_, camera) = try CameraFixture.razer()
        #expect(camera.name == "Razer Kiyo Pro")
    }
}
