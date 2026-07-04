//
//  DeviceListTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraCLI

/// A hardware-free stand-in for a discovered input.
private struct MockInput: Input {
    let id: InputID
    let name: String
    let kind: InputKind

    /// Creates a mock from bare strings, for terse fixtures.
    init(_ id: String, _ name: String, _ kind: InputKind) {
        self.id = InputID(rawValue: id)
        self.name = name
        self.kind = kind
    }

    func start() async throws {}

    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

/// The CLI.md example hardware, deliberately out of listing order.
private let fixtureInputs: [any Input] = [
    MockInput("0x14100000046d085e", "Logitech BRIO", .camera),
    MockInput("BuiltInMicrophoneDevice", "MacBook Pro Microphone", .microphone),
    MockInput("0x8020000005ac8514", "FaceTime HD Camera", .camera),
    MockInput("AppleUSBAudioEngine:Shure:MV7", "Shure MV7", .microphone),
]

@Suite("DeviceList building")
struct DeviceListBuildingTests {
    @Test("sections are filtered by kind, sorted by name, and indexed from zero")
    func buildsSortedIndexedSections() throws {
        let listing = DeviceList(inputs: fixtureInputs, type: .all)

        let cameras = try #require(listing.cameras)
        #expect(
            cameras == [
                Device(index: 0, name: "FaceTime HD Camera", id: "0x8020000005ac8514"),
                Device(index: 1, name: "Logitech BRIO", id: "0x14100000046d085e"),
            ])
        let microphones = try #require(listing.microphones)
        #expect(
            microphones == [
                Device(index: 0, name: "MacBook Pro Microphone", id: "BuiltInMicrophoneDevice"),
                Device(index: 1, name: "Shure MV7", id: "AppleUSBAudioEngine:Shure:MV7"),
            ])
    }

    @Test("devices sharing a name sort by identifier, so indexes stay deterministic")
    func identicalNamesSortByIdentifier() throws {
        let inputs: [any Input] = [
            MockInput("uid-b", "USB Camera", .camera),
            MockInput("uid-a", "USB Camera", .camera),
        ]
        let cameras = try #require(DeviceList(inputs: inputs, type: .camera).cameras)
        #expect(cameras.map(\.id) == ["uid-a", "uid-b"])
    }

    @Test("--type camera omits the microphones section; --type mic omits cameras")
    func typeFilterOmitsSections() {
        let camerasOnly = DeviceList(inputs: fixtureInputs, type: .camera)
        #expect(camerasOnly.cameras != nil)
        #expect(camerasOnly.microphones == nil)

        let microphonesOnly = DeviceList(inputs: fixtureInputs, type: .mic)
        #expect(microphonesOnly.cameras == nil)
        #expect(microphonesOnly.microphones != nil)
    }

    @Test("a requested kind with nothing connected is an empty array, not absent")
    func requestedEmptySectionIsEmptyArray() {
        let listing = DeviceList(inputs: [], type: .all)
        #expect(listing.cameras == [])
        #expect(listing.microphones == [])
    }
}

@Suite("DeviceList table")
struct DeviceListTableTests {
    @Test("the table matches the CLI.md format, names column-aligned")
    func tableMatchesFormat() {
        let table = DeviceList(inputs: fixtureInputs, type: .all).table
        let expected = """
            CAMERAS
              0  FaceTime HD Camera  (id: 0x8020000005ac8514)
              1  Logitech BRIO       (id: 0x14100000046d085e)
            MICROPHONES
              0  MacBook Pro Microphone  (id: BuiltInMicrophoneDevice)
              1  Shure MV7               (id: AppleUSBAudioEngine:Shure:MV7)
            """
        #expect(table == expected)
    }

    @Test("an empty section renders (none) under its title")
    func emptySectionRendersNone() {
        let table = DeviceList(inputs: [], type: .camera).table
        #expect(table == "CAMERAS\n  (none)")
    }

    @Test("a filtered listing renders only the requested section")
    func filteredListingRendersOneSection() {
        let table = DeviceList(inputs: fixtureInputs, type: .mic).table
        #expect(!table.contains("CAMERAS"))
        #expect(table.contains("MICROPHONES"))
    }
}

@Suite("DeviceList JSON contract")
struct DeviceListCodableTests {
    @Test("the listing encodes with the stable keys and round-trips")
    func roundTrip() throws {
        let original = DeviceList(inputs: fixtureInputs, type: .all)

        let data = try JSONEncoder().encode(original)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""cameras""#))
        #expect(json.contains(#""microphones""#))
        #expect(json.contains(#""index""#))
        #expect(json.contains(#""name""#))
        #expect(json.contains(#""id""#))

        let decoded = try JSONDecoder().decode(DeviceList.self, from: data)
        #expect(decoded == original)
    }

    @Test("missing optional sections decode as nil")
    func missingSectionsDecodeAsNil() throws {
        let decoded = try JSONDecoder().decode(DeviceList.self, from: Data("{}".utf8))
        #expect(decoded.cameras == nil)
        #expect(decoded.microphones == nil)
    }

    @Test(
        "a device missing a required field throws keyNotFound",
        arguments: [
            #"{"name": "FaceTime HD Camera", "id": "0x8020000005ac8514"}"#,
            #"{"index": 0, "id": "0x8020000005ac8514"}"#,
            #"{"index": 0, "name": "FaceTime HD Camera"}"#,
        ])
    func missingRequiredFieldThrows(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Device.self, from: Data(json.utf8))
        }
    }

    @Test("equal listings compare equal; different listings do not")
    func equality() {
        let a = DeviceList(cameras: [Device(index: 0, name: "A", id: "1")], microphones: nil)
        let b = DeviceList(cameras: [Device(index: 0, name: "A", id: "1")], microphones: nil)
        let c = DeviceList(cameras: [Device(index: 0, name: "B", id: "2")], microphones: nil)
        #expect(a == b)
        #expect(a != c)
    }
}
