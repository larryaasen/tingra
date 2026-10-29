//
//  VideoControlTopologyTests.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraUVC

/// Parsing a configuration descriptor into the VideoControl interface's
/// camera terminal and processing unit.
@Suite("Video control topology")
struct VideoControlTopologyTests {
    @Test("the Razer's descriptor yields its interface, camera terminal, and processing unit")
    func parsesTheRazerLayout() throws {
        let topology = try VideoControlTopology(
            configurationDescriptor: CameraFixture.descriptor(),
            deviceName: "Razer Kiyo Pro"
        )
        #expect(topology.interfaceNumber == 0)
        #expect(topology.cameraTerminal == .init(id: 1, controls: [0x2E, 0x0A, 0x02]))
        #expect(topology.processingUnit == .init(id: 3, controls: [0x5B, 0x17]))
    }

    @Test("an entity advertises exactly the bits its bitmap sets")
    func readsAdvertisedBits() throws {
        let topology = try VideoControlTopology(
            configurationDescriptor: CameraFixture.descriptor(),
            deviceName: "Razer Kiyo Pro"
        )
        let processing = try #require(topology.processingUnit)
        #expect(processing.advertises(bit: UVCControlKind.brightness.controlBit))
        #expect(processing.advertises(bit: UVCControlKind.whiteBalanceTemperatureAuto.controlBit))
        #expect(!processing.advertises(bit: UVCControlKind.hue.controlBit))
        #expect(!processing.advertises(bit: UVCControlKind.gamma.controlBit))
        let camera = try #require(topology.cameraTerminal)
        #expect(camera.advertises(bit: UVCControlKind.focusAuto.controlBit))
        #expect(!camera.advertises(bit: 40))
    }

    @Test("a descriptor with no VideoControl interface throws noVideoControlInterface")
    func throwsWithoutVideoControl() {
        let audioOnly: [UInt8] = [9, 0x02, 18, 0, 1, 1, 0, 0x80, 250, 9, 0x04, 0, 0, 0, 0x01, 0x01, 0, 0]
        #expect(throws: UVCError.noVideoControlInterface(name: "Speaker")) {
            try VideoControlTopology(configurationDescriptor: audioOnly, deviceName: "Speaker")
        }
    }

    @Test("a zero-length descriptor throws malformedDescriptor rather than looping")
    func throwsOnZeroLength() {
        var bytes = CameraFixture.descriptor()
        bytes[9] = 0
        #expect(throws: UVCError.self) {
            try VideoControlTopology(configurationDescriptor: bytes, deviceName: "Camera")
        }
    }

    @Test("a descriptor that runs past the end throws malformedDescriptor")
    func throwsOnOverrun() {
        let bytes = Array(CameraFixture.descriptor().prefix(30))
        #expect {
            try VideoControlTopology(configurationDescriptor: bytes, deviceName: "Camera")
        } throws: { error in
            guard case UVCError.malformedDescriptor = error else { return false }
            return true
        }
    }

    @Test("a control bitmap larger than its descriptor throws malformedDescriptor")
    func throwsOnOversizedBitmap() throws {
        var bytes = CameraFixture.descriptor()
        // The processing unit's bControlSize, claiming more than it holds.
        let unitStart = 9 + 8 + 9 + 13 + 18
        #expect(bytes[unitStart + 2] == 0x05)
        bytes[unitStart + 7] = 9
        #expect {
            try VideoControlTopology(configurationDescriptor: bytes, deviceName: "Camera")
        } throws: { error in
            guard case UVCError.malformedDescriptor = error else { return false }
            return true
        }
    }

    @Test("an input terminal that is not a camera is not taken for the camera terminal")
    func ignoresNonCameraInputTerminals() throws {
        var bytes = CameraFixture.descriptor()
        let terminalStart = 9 + 8 + 9 + 13
        bytes[terminalStart + 4] = 0x01
        bytes[terminalStart + 5] = 0x04
        let topology = try VideoControlTopology(configurationDescriptor: bytes, deviceName: "Camera")
        #expect(topology.cameraTerminal == nil)
        #expect(topology.processingUnit != nil)
    }

    @Test("entity lookup routes each kind to its own entity")
    func routesKindsToEntities() throws {
        let topology = try VideoControlTopology(
            configurationDescriptor: CameraFixture.descriptor(),
            deviceName: "Camera"
        )
        #expect(topology.entity(for: .zoom)?.id == 1)
        #expect(topology.entity(for: .brightness)?.id == 3)
    }
}
