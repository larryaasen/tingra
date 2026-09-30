//
//  PlugInLoadReportTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-29.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

@Suite("PlugInLoadReport")
struct PlugInLoadReportTests {
    /// A report with one entry in each shape: a compiled-in plug-in, and a
    /// refused bundle carrying every optional value.
    private let report = PlugInLoadReport(
        kitVersion: "0.1.0", safeMode: false, folders: ["~/Library/Application Support/Tingra/Plug-ins"],
        plugIns: [
            PlugInLoadReport.Entry(
                id: "com.moonwink.tingra.capture", name: "Capture", version: nil, source: .compiledIn, path: nil,
                state: .active, reason: nil, message: nil, warnings: []),
            PlugInLoadReport.Entry(
                id: "com.example.alpha", name: "Alpha", version: "1.0", source: .bundle,
                path: "~/Library/Application Support/Tingra/Plug-ins/Alpha.tingraplugin", state: .refused,
                reason: "unsigned", message: "'Alpha.tingraplugin' has no valid code signature.",
                warnings: ["an embedded kit"]),
        ])

    /// Decodes an entry from a JSON object literal.
    private func entry(_ json: String) throws -> PlugInLoadReport.Entry {
        try JSONDecoder().decode(PlugInLoadReport.Entry.self, from: Data(json.utf8))
    }

    @Test("a report round-trips through JSON unchanged")
    func roundTrips() throws {
        let data = try JSONEncoder().encode(report)

        #expect(try JSONDecoder().decode(PlugInLoadReport.self, from: data) == report)
    }

    @Test("the document's keys are the stable camelCase contract, and an absent value is written as null")
    func keysAndNulls() throws {
        let data = try JSONEncoder().encode(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["plugIns"] as? [[String: Any]])

        #expect(Set(object.keys) == ["kitVersion", "safeMode", "folders", "plugIns"])
        #expect(
            Set(entries[0].keys)
                == ["id", "name", "version", "source", "path", "state", "reason", "message", "warnings"])
        #expect(entries[0]["path"] is NSNull)
        #expect(entries[0]["source"] as? String == "compiledIn")
        #expect(entries[1]["state"] as? String == "refused")
    }

    @Test("an entry missing an optional key decodes it as nil")
    func missingOptionalKeys() throws {
        let decoded = try entry(#"{"name":"Alpha","source":"bundle","state":"skipped","warnings":[]}"#)

        #expect(decoded.id == nil)
        #expect(decoded.version == nil)
        #expect(decoded.path == nil)
        #expect(decoded.reason == nil)
        #expect(decoded.message == nil)
    }

    @Test("an entry missing a required key throws keyNotFound", arguments: ["name", "source", "state", "warnings"])
    func missingRequiredKeyThrows(key: String) throws {
        var fields: [String: Any] = ["name": "Alpha", "source": "bundle", "state": "active", "warnings": []]
        fields[key] = nil
        let data = try JSONSerialization.data(withJSONObject: fields)

        #expect {
            try JSONDecoder().decode(PlugInLoadReport.Entry.self, from: data)
        } throws: { error in
            guard case DecodingError.keyNotFound(let missing, _) = error else { return false }
            return missing.stringValue == key
        }
    }

    @Test(
        "a report missing a top-level key throws keyNotFound",
        arguments: ["kitVersion", "safeMode", "folders", "plugIns"])
    func missingTopLevelKeyThrows(key: String) throws {
        var fields: [String: Any] = ["kitVersion": "0.1.0", "safeMode": false, "folders": [], "plugIns": []]
        fields[key] = nil
        let data = try JSONSerialization.data(withJSONObject: fields)

        #expect {
            try JSONDecoder().decode(PlugInLoadReport.self, from: data)
        } throws: { error in
            guard case DecodingError.keyNotFound(let missing, _) = error else { return false }
            return missing.stringValue == key
        }
    }

    @Test("an unknown state throws rather than guessing")
    func unknownStateThrows() {
        #expect(throws: DecodingError.self) {
            try entry(#"{"name":"Alpha","source":"bundle","state":"sleeping","warnings":[]}"#)
        }
    }

    @Test("reports are equal when every value is, and differ when one does")
    func equality() {
        let other = PlugInLoadReport(
            kitVersion: report.kitVersion, safeMode: true, folders: report.folders, plugIns: report.plugIns)

        #expect(
            report
                == PlugInLoadReport(
                    kitVersion: "0.1.0", safeMode: false, folders: report.folders, plugIns: report.plugIns))
        #expect(report != other)
        #expect(report.plugIns[0] != report.plugIns[1])
    }
}
