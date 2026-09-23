//
//  MeterLevelsTests.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraAppPlugInKit

/// The `tingra/meters` notification's payload: its JSON shape, which is the
/// wire contract, and what a reader makes of a malformed one.
@Suite("Meter levels")
struct MeterLevelsTests {
    /// One window: two strips and a lopsided master.
    private let levels = MeterLevels(
        time: 42.25,
        strips: [
            InputID(rawValue: "mic"): MeterLevel(peak: 0.5, rms: 0.25),
            InputID(rawValue: "tone"): .floor,
        ],
        masterLeft: MeterLevel(peak: 1.25, rms: 0.5), masterRight: MeterLevel(peak: 0.125, rms: 0.0625))

    @Test("the levels render as time, strips by input id, and a left and right master")
    func rendersShape() {
        let json = levels.jsonValue
        #expect(json["time"] == .double(42.25))
        #expect(json["strips"]?["mic"] == .object(["peak": .double(0.5), "rms": .double(0.25)]))
        #expect(json["strips"]?["tone"] == .object(["peak": .double(0), "rms": .double(0)]))
        #expect(json["master"]?["left"]?["peak"] == .double(1.25))
        #expect(json["master"]?["right"]?["rms"] == .double(0.0625))
    }

    @Test("the levels round-trip through their JSON, as text too")
    func roundTrips() throws {
        #expect(MeterLevels(jsonValue: levels.jsonValue) == levels)
        let text = try JSONEncoder().encode(levels.jsonValue)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: text)
        #expect(MeterLevels(jsonValue: decoded) == levels)
    }

    @Test("levels that differ in one figure are not equal")
    func differingLevelsNotEqual() {
        let other = MeterLevels(
            time: levels.time, strips: levels.strips, masterLeft: levels.masterLeft, masterRight: .floor)
        #expect(other != levels)
        #expect(MeterLevel(peak: 0.5, rms: 0.25) != MeterLevel(peak: 0.5, rms: 0.5))
    }

    @Test("a whole number reads as a level, the way JSON writes 1.0")
    func readsIntegers() {
        #expect(MeterLevel(jsonValue: .object(["peak": .int(1), "rms": .int(0)])) == MeterLevel(peak: 1, rms: 0))
    }

    @Test(
        "params missing a member do not read",
        arguments: ["time", "strips", "master"])
    func missingMemberDoesNotRead(member: String) throws {
        var members = try #require(levels.jsonValue.objectValue)
        members[member] = nil
        #expect(MeterLevels(jsonValue: .object(members)) == nil)
    }

    @Test("a strip or a master channel without both figures does not read")
    func malformedLevelDoesNotRead() throws {
        var members = try #require(levels.jsonValue.objectValue)
        members["strips"] = .object(["mic": .object(["peak": .double(0.5)])])
        #expect(MeterLevels(jsonValue: .object(members)) == nil)
        members = try #require(levels.jsonValue.objectValue)
        members["master"] = .object(["left": MeterLevel.floor.jsonValue])
        #expect(MeterLevels(jsonValue: .object(members)) == nil)
        #expect(MeterLevels(jsonValue: nil) == nil)
        #expect(MeterLevel(jsonValue: .object(["peak": .string("loud"), "rms": .double(0)])) == nil)
    }

    @Test("a magnitude converts to dBFS, and silence to negative infinity")
    func convertsToDecibels() {
        #expect(MeterLevel.decibels(1) == 0)
        #expect(abs(MeterLevel.decibels(0.5) - -6.0206) < 0.001)
        #expect(MeterLevel.decibels(0) == -.infinity)
    }
}
