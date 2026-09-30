//
//  PlugInEnablementTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraHost

/// A temporary folder for one test's enablement file, removed when the test
/// ends.
private struct StateFolder {
    /// The folder.
    let url = FileManager.default.temporaryDirectory.appending(
        path: "PlugInEnablementTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// The store over a file in the folder.
    var store: PlugInEnablementStore { PlugInEnablementStore(directory: url) }

    /// Deletes the folder and everything in it.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A crash record for tests.
private func crash(_ id: String, cdHash: String = "abc123") -> CrashedPlugInBundle {
    CrashedPlugInBundle(
        id: PlugInID(rawValue: id), cdHash: cdHash, path: "~/Library/Application Support/Tingra/Plug-ins/A",
        frontEnd: "tingra-cli serve", date: Date(timeIntervalSince1970: 1_790_000_000))
}

@Suite("PlugInEnablement")
struct PlugInEnablementTests {
    @Test("turning a plug-in off records it once, in id order")
    func disableRecordsOnce() {
        var enablement = PlugInEnablement()

        enablement.disable(PlugInID(rawValue: "com.example.zeta"))
        enablement.disable(PlugInID(rawValue: "com.example.alpha"))
        enablement.disable(PlugInID(rawValue: "com.example.zeta"))

        #expect(enablement.disabled.map(\.rawValue) == ["com.example.alpha", "com.example.zeta"])
        #expect(enablement.isDisabled(PlugInID(rawValue: "com.example.zeta")))
        #expect(!enablement.isDisabled(PlugInID(rawValue: "com.example.beta")))
    }

    @Test("turning a plug-in back on clears both the operator's choice and a crash")
    func enableClearsBoth() {
        let id = PlugInID(rawValue: "com.example.alpha")
        var enablement = PlugInEnablement(disabled: [id], crashed: [crash("com.example.alpha")])

        enablement.enable(id)

        #expect(enablement == PlugInEnablement())
    }

    @Test("a second crash of the same plug-in replaces the first")
    func recordCrashReplaces() {
        var enablement = PlugInEnablement()

        enablement.recordCrash(crash("com.example.alpha", cdHash: "old"))
        enablement.recordCrash(crash("com.example.alpha", cdHash: "new"))

        #expect(enablement.crashed.map(\.cdHash) == ["new"])
        #expect(enablement.crash(of: PlugInID(rawValue: "com.example.alpha"))?.cdHash == "new")
        #expect(enablement.crash(of: PlugInID(rawValue: "com.example.beta")) == nil)
    }

    @Test("records with the same entries are equal; records that differ are not")
    func equality() {
        let id = PlugInID(rawValue: "com.example.alpha")

        #expect(PlugInEnablement(disabled: [id]) == PlugInEnablement(disabled: [id, id]))
        #expect(PlugInEnablement(disabled: [id]) != PlugInEnablement())
        #expect(PlugInEnablement(crashed: [crash("a", cdHash: "1")]) != PlugInEnablement(crashed: [crash("a")]))
    }

    @Test("a record encodes both lists under stable keys and decodes back to itself")
    func roundTrips() throws {
        let enablement = PlugInEnablement(
            disabled: [PlugInID(rawValue: "com.example.beta")], crashed: [crash("com.example.alpha")])

        let data = try JSONEncoder.plugInEnablement.encode(enablement)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let crashed = try #require((object["crashed"] as? [[String: Any]])?.first)

        #expect(Set(object.keys) == ["disabled", "crashed"])
        #expect(Set(crashed.keys) == ["id", "cdHash", "path", "frontEnd", "date"])
        #expect(crashed["date"] as? String == "2026-09-21T14:13:20Z")
        #expect(try JSONDecoder.plugInEnablement.decode(PlugInEnablement.self, from: data) == enablement)
    }

    @Test("an empty record still writes both lists")
    func emptyRecordWritesBothLists() throws {
        let data = try JSONEncoder.plugInEnablement.encode(PlugInEnablement())

        #expect(String(decoding: data, as: UTF8.self).contains("\"crashed\" : ["))
        #expect(String(decoding: data, as: UTF8.self).contains("\"disabled\" : ["))
    }

    @Test("a file missing either list decodes it as empty", arguments: ["{}", #"{"disabled":[]}"#, #"{"crashed":[]}"#])
    func missingListsDecodeAsEmpty(_ json: String) throws {
        let enablement = try JSONDecoder.plugInEnablement.decode(PlugInEnablement.self, from: Data(json.utf8))

        #expect(enablement == PlugInEnablement())
    }

    @Test(
        "a crash record missing a required field throws keyNotFound",
        arguments: ["id", "cdHash", "path", "frontEnd", "date"])
    func crashMissingFieldThrows(_ missing: String) throws {
        var fields: [String: String] = [
            "id": "com.example.alpha", "cdHash": "abc", "path": "~/A", "frontEnd": "Tingra",
            "date": "2026-09-28T12:00:00Z",
        ]
        fields[missing] = nil
        let json = try JSONSerialization.data(withJSONObject: ["crashed": [fields]])

        #expect {
            try JSONDecoder.plugInEnablement.decode(PlugInEnablement.self, from: json)
        } throws: { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return false }
            return key.stringValue == missing
        }
    }

    @Test("a missing file reads as nothing turned off, and a change creates it")
    func missingFileReadsEmpty() throws {
        let folder = StateFolder()
        defer { folder.remove() }
        let id = PlugInID(rawValue: "com.example.alpha")

        #expect(try folder.store.read() == PlugInEnablement())
        try folder.store.update { $0.disable(id) }

        #expect(try folder.store.read().isDisabled(id))
        #expect(folder.store.fileURL.lastPathComponent == "plug-ins.json")
    }

    @Test("a change that changes nothing writes nothing")
    func noOpUpdateWritesNothing() throws {
        let folder = StateFolder()
        defer { folder.remove() }

        try folder.store.update { $0.enable(PlugInID(rawValue: "com.example.alpha")) }

        #expect(!FileManager.default.fileExists(atPath: folder.store.fileURL.path(percentEncoded: false)))
    }

    @Test("an unreadable file throws, naming its path, and a change never overwrites it")
    func unreadableFileIsLeftAlone() throws {
        let folder = StateFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data("[1, 2".utf8).write(to: folder.store.fileURL)

        #expect {
            try folder.store.update { $0.disable(PlugInID(rawValue: "com.example.alpha")) }
        } throws: { error in
            guard case PlugInEnablementStoreError.unreadable(let path, _) = error else { return false }
            return path.hasSuffix("plug-ins.json")
        }
        #expect(try Data(contentsOf: folder.store.fileURL) == Data("[1, 2".utf8))
    }

    @Test("the unreadable file's description says nothing loads until it is repaired or removed")
    func unreadableDescription() {
        let description = PlugInEnablementStoreError.unreadable(path: "~/x/plug-ins.json", reason: "bad").description

        #expect(description.contains("~/x/plug-ins.json"))
        #expect(description.contains("loads no plug-in bundles"))
        #expect(description.contains("Removing it turns every plug-in back on"))
    }

    @Test("the standard file sits in Tingra's Application Support folder")
    func standardLocation() {
        let path = PlugInEnablementStore().fileURL.path(percentEncoded: false)

        #expect(path.hasSuffix("Library/Application Support/Tingra/plug-ins.json"))
    }
}
