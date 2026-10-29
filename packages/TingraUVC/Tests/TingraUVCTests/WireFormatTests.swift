//
//  WireFormatTests.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraUVC

/// The bytes on the wire: request setup fields, value encoding, and the
/// capture device unique ID that leads to a camera's USB address.
@Suite("Wire format")
struct WireFormatTests {
    @Test("a get request is class-specific, device-to-host, addressed to the entity's interface")
    func encodesAGetRequest() {
        let request = UVCRequest(code: .getCurrent, selector: 0x0A, entityID: 3, interfaceNumber: 0, length: 2)
        #expect(request.requestType == 0xA1)
        #expect(request.value == 0x0A00)
        #expect(request.index == 0x0300)
        #expect(request.code.isGet)
    }

    @Test("a set request is host-to-device")
    func encodesASetRequest() {
        let request = UVCRequest(code: .setCurrent, selector: 0x02, entityID: 3, interfaceNumber: 1, length: 2)
        #expect(request.requestType == 0x21)
        #expect(request.index == 0x0301)
        #expect(!request.code.isGet)
    }

    @Test("every get code has its high bit set and the set code does not")
    func classifiesRequestCodes() {
        let gets = UVCRequestCode.allCases.filter(\.isGet)
        #expect(gets.count == UVCRequestCode.allCases.count - 1)
        #expect(!gets.contains(.setCurrent))
    }

    @Test("a signed two-byte value round-trips through encode and decode")
    func roundTripsSignedValues() {
        var payload = [UInt8](repeating: 0, count: 2)
        UVCControlKind.brightness.encode(-64, into: &payload)
        #expect(payload == [0xC0, 0xFF])
        #expect(UVCControlKind.brightness.decode(payload) == -64)
    }

    @Test("an unsigned two-byte value does not sign-extend")
    func decodesUnsignedValues() {
        #expect(UVCControlKind.contrast.decode([0xFF, 0xFF]) == 65535)
    }

    @Test("a four-byte exposure time decodes little-endian")
    func decodesFourBytes() {
        #expect(UVCControlKind.exposureTime.decode([0xC3, 0x03, 0, 0]) == 963)
    }

    @Test("a payload too short for the field decodes to nil")
    func rejectsShortPayloads() {
        #expect(UVCControlKind.brightness.decode([0x01]) == nil)
        #expect(UVCControlKind.tilt.decode([0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test("every control's field fits inside its payload")
    func fieldsFitTheirPayloads() {
        for kind in UVCControlKind.allCases {
            #expect(kind.fieldOffset + kind.fieldSize <= kind.payloadLength, "\(kind)")
        }
    }

    @Test("a USB camera's capture unique ID parses to its location, vendor, and product")
    func parsesACaptureUniqueID() throws {
        let address = try #require(CaptureDeviceAddress(uniqueID: "0x211100015320e05"))
        #expect(address.locationID == 0x0211_1000)
        #expect(address.vendorID == 0x1532)
        #expect(address.productID == 0x0E05)
        #expect(
            address.matches(
                UVCDevice(id: 1, name: "Razer Kiyo Pro", vendorID: 0x1532, productID: 0x0E05, locationID: 0x0211_1000)
            ))
        #expect(
            !address.matches(
                UVCDevice(id: 2, name: "Razer Kiyo Pro", vendorID: 0x1532, productID: 0x0E05, locationID: 0x0211_2000)
            ))
    }

    @Test("a built-in or Continuity camera's unique ID is not a USB address")
    func rejectsNonUSBUniqueIDs() {
        #expect(CaptureDeviceAddress(uniqueID: "1FD4B3A2-236E-492B-8CE5-255DD288CE50") == nil)
        #expect(CaptureDeviceAddress(uniqueID: "E91CB192-44A3-437C-AF09-9E1F00000001") == nil)
        #expect(CaptureDeviceAddress(uniqueID: "0x15320e05") == nil)
        #expect(CaptureDeviceAddress(uniqueID: "0xZZ1100015320e05") == nil)
        #expect(CaptureDeviceAddress(uniqueID: "") == nil)
    }

    @Test("matching a non-USB unique ID finds nothing without searching the registry")
    func matchesNothingForNonUSBIDs() throws {
        #expect(try UVCDevice.matching(captureDeviceUniqueID: "1FD4B3A2-236E-492B-8CE5-255DD288CE50") == nil)
    }

    @Test("every error explains itself")
    func describesEveryError() {
        let request = UVCRequest(code: .getMinimum, selector: 0x03, entityID: 3, interfaceNumber: 0, length: 2)
        let errors: [UVCError] = [
            .registryUnavailable("-536870212"),
            .deviceNotFound(name: "Razer Kiyo Pro"),
            .openFailed(name: "Razer Kiyo Pro", reason: "exclusive access"),
            .noVideoControlInterface(name: "Speaker"),
            .malformedDescriptor("short"),
            .requestFailed(request, reason: "stalled"),
            .shortResponse(request, received: 1),
            .controlNotSettable(.brightness),
            .valueOutOfRange(.zoom, value: 500, range: 100...400),
            .unsupportedAutoExposureMode(2, supported: [.manual, .aperturePriority]),
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
        #expect(UVCError.requestFailed(request, reason: "stalled").description.contains("GET_MIN"))
        #expect(UVCError.deviceNotFound(name: "A") == .deviceNotFound(name: "A"))
        #expect(UVCError.deviceNotFound(name: "A") != .deviceNotFound(name: "B"))
    }
}
