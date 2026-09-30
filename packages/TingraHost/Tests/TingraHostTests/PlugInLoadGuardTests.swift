//
//  PlugInLoadGuardTests.swift
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

/// A guard over a temporary folder, removed when the test ends.
private struct GuardFolder {
    /// The folder holding the markers.
    let url = FileManager.default.temporaryDirectory.appending(
        path: "PlugInLoadGuardTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A guard writing markers for the given process into the folder.
    func loadGuard(for process: ProcessIdentity = .current) -> PlugInLoadGuard {
        PlugInLoadGuard(directory: url, process: process)
    }

    /// Deletes the folder and everything in it.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A marker naming a bundle for a process.
private func marker(for process: ProcessIdentity, id: String = "com.example.alpha") -> PlugInLoadMarker {
    PlugInLoadMarker(
        id: PlugInID(rawValue: id), path: "~/Alpha.tingraplugin", cdHash: "abc", frontEnd: "Tingra", process: process)
}

/// A process that is gone: this process's id with a start time it never had.
private let goneProcess = ProcessIdentity(processID: getpid(), startTime: 1)

@Suite("PlugInLoadGuard")
struct PlugInLoadGuardTests {
    @Test("this process is running")
    func currentProcessIsRunning() {
        #expect(ProcessIdentity.current.isRunning)
        #expect(ProcessIdentity.current.processID == getpid())
    }

    @Test("a process id reused by a later process is not the process that was recorded")
    func reusedIDIsNotRunning() {
        #expect(!goneProcess.isRunning)
    }

    @Test("a process that has exited is not running")
    func exitedProcessIsNotRunning() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        let identity = ProcessIdentity(
            processID: process.processIdentifier,
            startTime: ProcessIdentity.startTime(of: process.processIdentifier) ?? 0)
        process.waitUntilExit()

        #expect(!identity.isRunning)
    }

    @Test("begin writes this process's marker and end removes it")
    func beginAndEnd() throws {
        let folder = GuardFolder()
        defer { folder.remove() }
        let loadGuard = folder.loadGuard()
        let url = loadGuard.markerURL(for: .current)

        loadGuard.begin(marker(for: .current))
        let written = try JSONDecoder().decode(PlugInLoadMarker.self, from: Data(contentsOf: url))
        loadGuard.end()

        #expect(written == marker(for: .current))
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("a marker is named for its process's id and start, so a reused id never overwrites it")
    func markerNamesItsProcess() {
        let loadGuard = GuardFolder().loadGuard()

        #expect(loadGuard.markerURL(for: goneProcess).lastPathComponent == "\(getpid())-1.json")
        #expect(loadGuard.markerURL(for: goneProcess) != loadGuard.markerURL(for: .current))
    }

    @Test("only markers of processes that are gone are abandoned, never this process's own")
    func abandonedMarkersAreTheDeadOnes() throws {
        let folder = GuardFolder()
        defer { folder.remove() }
        let launchd = ProcessIdentity(processID: 1, startTime: try #require(ProcessIdentity.startTime(of: 1)))
        folder.loadGuard(for: goneProcess).begin(marker(for: goneProcess, id: "com.example.gone"))
        folder.loadGuard(for: launchd).begin(marker(for: launchd, id: "com.example.running"))
        folder.loadGuard().begin(marker(for: .current, id: "com.example.mine"))

        let abandoned = folder.loadGuard().abandonedMarkers()

        #expect(abandoned.map(\.id.rawValue) == ["com.example.gone"])
    }

    @Test("a marker is claimed once, so two front ends never both report one crash")
    func claimIsOnce() {
        let folder = GuardFolder()
        defer { folder.remove() }
        folder.loadGuard(for: goneProcess).begin(marker(for: goneProcess))
        let found = folder.loadGuard().abandonedMarkers()

        #expect(found.count == 1)
        #expect(found.first.map { folder.loadGuard().claim($0) } == true)
        #expect(found.first.map { folder.loadGuard().claim($0) } == false)
        #expect(folder.loadGuard().abandonedMarkers().isEmpty)
    }

    @Test("a marker that does not decode is not evidence, and is left alone")
    func undecodableMarkerIsIgnored() throws {
        let folder = GuardFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let junk = folder.url.appending(path: "123-4.json")
        try Data("{".utf8).write(to: junk)

        #expect(folder.loadGuard().abandonedMarkers().isEmpty)
        #expect(FileManager.default.fileExists(atPath: junk.path(percentEncoded: false)))
    }

    @Test("a missing folder holds no markers")
    func missingFolderHoldsNone() {
        #expect(GuardFolder().loadGuard().abandonedMarkers().isEmpty)
    }

    @Test("a marker round-trips under stable keys")
    func markerRoundTrips() throws {
        let original = marker(for: goneProcess)

        let data = try JSONEncoder().encode(original)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["id", "path", "cdHash", "frontEnd", "process"])
        #expect(Set((object["process"] as? [String: Any])?.keys ?? [:].keys) == ["processID", "startTime"])
        #expect(try JSONDecoder().decode(PlugInLoadMarker.self, from: data) == original)
    }

    @Test(
        "a marker missing a required field throws keyNotFound",
        arguments: ["id", "path", "cdHash", "frontEnd", "process"])
    func markerMissingFieldThrows(_ missing: String) throws {
        var fields: [String: Any] = [
            "id": "com.example.alpha", "path": "~/A", "cdHash": "abc", "frontEnd": "Tingra",
            "process": ["processID": 1, "startTime": 2],
        ]
        fields[missing] = nil
        let json = try JSONSerialization.data(withJSONObject: fields)

        #expect {
            try JSONDecoder().decode(PlugInLoadMarker.self, from: json)
        } throws: { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return false }
            return key.stringValue == missing
        }
    }

    @Test("identities are equal only when both the id and the start match")
    func identityEquality() {
        #expect(ProcessIdentity(processID: 5, startTime: 6) == ProcessIdentity(processID: 5, startTime: 6))
        #expect(ProcessIdentity(processID: 5, startTime: 6) != ProcessIdentity(processID: 5, startTime: 7))
        #expect(ProcessIdentity(processID: 5, startTime: 6) != ProcessIdentity(processID: 4, startTime: 6))
    }
}
