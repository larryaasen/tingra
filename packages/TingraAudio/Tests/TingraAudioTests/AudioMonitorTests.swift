//
//  AudioMonitorTests.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraAudio

@Suite("AudioMonitorDevice")
struct AudioMonitorDeviceTests {
    @Test("a device is identified by its stable Core Audio UID")
    func identityIsTheUID() {
        let device = AudioMonitorDevice(uid: "BuiltInHeadphoneOutputDevice", name: "External Headphones")
        #expect(device.id == "BuiltInHeadphoneOutputDevice")
    }

    @Test("devices with the same uid and name are equal")
    func equalDevicesMatch() {
        #expect(
            AudioMonitorDevice(uid: "uid-1", name: "Studio Monitors")
                == AudioMonitorDevice(uid: "uid-1", name: "Studio Monitors"))
    }

    @Test("devices differing in uid or in name are not equal")
    func differingDevicesDoNotMatch() {
        let device = AudioMonitorDevice(uid: "uid-1", name: "Studio Monitors")
        #expect(device != AudioMonitorDevice(uid: "uid-2", name: "Studio Monitors"))
        #expect(device != AudioMonitorDevice(uid: "uid-1", name: "External Headphones"))
    }
}

@Suite("AudioMonitorError")
struct AudioMonitorErrorTests {
    @Test("a missing device names the device and the fix")
    func missingDeviceDescribesTheFix() {
        let description = AudioMonitorError.deviceNotFound(uid: "uid-1").description
        #expect(description.contains("uid-1"))
        #expect(description.localizedStandardContains("reconnect"))
    }

    @Test("a device that will not open reports the underlying reason and the fix")
    func couldNotStartDescribesTheReason() {
        let description =
            AudioMonitorError
            .couldNotStart(uid: "uid-1", reason: "the device is in use")
            .description
        #expect(description.contains("uid-1"))
        #expect(description.contains("the device is in use"))
        #expect(description.localizedStandardContains("choose another"))
    }

    @Test("errors of the same case and payload are equal, and differing ones are not")
    func errorEquality() {
        #expect(AudioMonitorError.deviceNotFound(uid: "a") == AudioMonitorError.deviceNotFound(uid: "a"))
        #expect(AudioMonitorError.deviceNotFound(uid: "a") != AudioMonitorError.deviceNotFound(uid: "b"))
        #expect(
            AudioMonitorError.deviceNotFound(uid: "a")
                != AudioMonitorError.couldNotStart(uid: "a", reason: "busy"))
    }
}

@Suite("StereoMeterReading")
struct StereoMeterReadingTests {
    @Test("the floor is silence on both program channels")
    func floorIsSilentOnBothChannels() {
        #expect(StereoMeterReading.floor.left == .floor)
        #expect(StereoMeterReading.floor.right == .floor)
    }

    @Test("readings with the same channels are equal, and differing ones are not")
    func stereoReadingEquality() {
        let reading = StereoMeterReading(
            left: MeterReading(peak: 0.5, rms: 0.25),
            right: MeterReading(peak: 0.5, rms: 0.25)
        )
        #expect(
            reading
                == StereoMeterReading(
                    left: MeterReading(peak: 0.5, rms: 0.25),
                    right: MeterReading(peak: 0.5, rms: 0.25)))
        // Channel order matters: a stereo reading exists precisely to tell
        // the two sides apart.
        #expect(
            reading
                != StereoMeterReading(
                    left: MeterReading(peak: 0.5, rms: 0.25),
                    right: MeterReading(peak: 0.25, rms: 0.25)))
    }

    @Test("a meter block built without a master reads the floor there")
    func meterBlockDefaultsToASilentMaster() {
        #expect(MeterBlock(time: .zero, strips: [:]).master == .floor)
    }
}
