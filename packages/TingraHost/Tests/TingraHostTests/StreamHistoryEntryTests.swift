//
//  StreamHistoryEntryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

/// The stream history's entry and summary: the file's JSON contract, the
/// length of a session, and the figures over a history.
@Suite("StreamHistoryEntry")
struct StreamHistoryEntryTests {
    /// A whole-second moment, since the file stores dates as ISO 8601.
    private static let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// A finished session.
    private static let finished = StreamHistoryEntry(
        number: 7,
        startedAt: start,
        endedAt: start.addingTimeInterval(3963),
        endReason: .stopped,
        destinations: ["Twitch", "YouTube"],
        width: 1920,
        height: 1080,
        frameRate: 30
    )

    /// A session with no recorded end.
    private static let open = StreamHistoryEntry(
        number: 8,
        startedAt: start,
        endedAt: nil,
        endReason: nil,
        destinations: ["Twitch"],
        width: 1280,
        height: 720,
        frameRate: 60
    )

    /// An encoder writing dates as the store does.
    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A decoder reading dates as the store does.
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A finished entry as a JSON object, for removing one key at a time.
    private func finishedObject() throws -> [String: Any] {
        let data = try encoder.encode(Self.finished)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a finished entry round-trips through JSON unchanged")
    func finishedRoundTrips() throws {
        let decoded = try decoder.decode(StreamHistoryEntry.self, from: encoder.encode(Self.finished))
        #expect(decoded == Self.finished)
    }

    @Test("an entry with no end round-trips, and its optional keys are left out of the JSON")
    func openRoundTrips() throws {
        let data = try encoder.encode(Self.open)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["endedAt"] == nil)
        #expect(object["endReason"] == nil)
        #expect(try decoder.decode(StreamHistoryEntry.self, from: data) == Self.open)
    }

    @Test("the JSON keys are the stable camelCase names")
    func keysAreStable() throws {
        #expect(
            Set(try finishedObject().keys) == [
                "number", "startedAt", "endedAt", "endReason", "destinations", "width", "height", "frameRate",
            ])
    }

    @Test(
        "decoding throws keyNotFound for each missing required key",
        arguments: ["number", "startedAt", "destinations", "width", "height", "frameRate"]
    )
    func missingRequiredKeyThrows(key: String) throws {
        var object = try finishedObject()
        object[key] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try decoder.decode(StreamHistoryEntry.self, from: data)
            Issue.record("decoding without \(key) returned an entry")
        } catch DecodingError.keyNotFound(let missing, _) {
            #expect(missing.stringValue == key)
        }
    }

    @Test("decoding without the optional keys reads an entry with no end")
    func missingOptionalKeysDecode() throws {
        var object = try finishedObject()
        object["endedAt"] = nil
        object["endReason"] = nil
        let decoded = try decoder.decode(StreamHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.endedAt == nil)
        #expect(decoded.endReason == nil)
        #expect(decoded.duration == nil)
    }

    @Test("the last moment on air round-trips, and gives an entry with no end its length")
    func lastOnAirRoundTrips() throws {
        var cutOff = Self.open
        cutOff.lastOnAirAt = Self.start.addingTimeInterval(250)
        let data = try encoder.encode(cutOff)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["lastOnAirAt"] != nil)
        #expect(try decoder.decode(StreamHistoryEntry.self, from: data) == cutOff)
        #expect(cutOff.duration == 250)
        #expect(cutOff != Self.open)
    }

    @Test("a recorded end decides the length over the last moment on air")
    func endOutranksLastOnAir() {
        var finished = Self.finished
        finished.lastOnAirAt = Self.start.addingTimeInterval(3900)
        #expect(finished.duration == 3963)
    }

    @Test("entries compare equal when every field matches and unequal when one differs")
    func equality() {
        var other = Self.finished
        #expect(other == Self.finished)
        other.endReason = .connectionLost
        #expect(other != Self.finished)
        #expect(Self.open != Self.finished)
    }

    @Test("the session number is the entry's identity")
    func identity() {
        #expect(Self.finished.id == 7)
    }

    @Test("the length is the end minus the start, nil without an end, and never negative")
    func duration() {
        #expect(Self.finished.duration == 3963)
        #expect(Self.open.duration == nil)
        var backwards = Self.open
        backwards.endedAt = Self.start.addingTimeInterval(-30)
        #expect(backwards.duration == 0)
    }

    @Test("the end reasons keep their stable raw values")
    func endReasonRawValues() {
        #expect(StreamHistoryEndReason.stopped.rawValue == "stopped")
        #expect(StreamHistoryEndReason.connectionLost.rawValue == "connectionLost")
        #expect(StreamHistoryEndReason.appQuit.rawValue == "appQuit")
    }

    @Test("a summary counts every session and sums the lengths of those with an end")
    func summary() {
        let summary = StreamHistorySummary([Self.finished, Self.open, Self.finished])
        #expect(summary.sessionCount == 3)
        #expect(summary.totalDuration == 7926)
        #expect(StreamHistorySummary([]) == StreamHistorySummary([]))
        #expect(StreamHistorySummary([]).sessionCount == 0)
        #expect(StreamHistorySummary([]).totalDuration == 0)
        #expect(summary != StreamHistorySummary([Self.finished]))
    }
}
