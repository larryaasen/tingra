//
//  RecordingLibraryModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus

@testable import TingraApp

/// What the model gives the Library's Recordings tab (ARCHITECTURE.md, "The
/// Recordings tab"): the take being written, the revision the tab re-reads
/// on, and Move to Trash's refusal of the take under its writer. The engine
/// is never started; the recording events arrive through the model's own
/// bus, as the session would send them, and every folder and preference is
/// a throwaway one, never the operator's.
@MainActor
@Suite("EngineModel recordings")
struct RecordingLibraryModelTests {
    /// A model whose recordings folder is a fresh temporary one, with the
    /// suite and folder to clean up.
    private struct Fixture {
        /// The model under test.
        let model: EngineModel

        /// The recordings folder, on disk.
        let folder: URL

        /// The throwaway defaults suite's name.
        let suiteName: String

        /// Creates the fixture.
        init() throws {
            suiteName = "RecordingLibraryModelTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            folder = URL.temporaryDirectory.appending(
                path: "tingra-recording-model-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let recordingPreferences = RecordingPreferences(defaults: defaults)
            recordingPreferences.folder = folder
            let snapshotPreferences = SnapshotPreferences(defaults: defaults)
            snapshotPreferences.folder = folder.appending(path: "Snapshots", directoryHint: .isDirectory)
            model = EngineModel(
                monitor: SilentMonitor(), snapshotPreferences: snapshotPreferences,
                recordingPreferences: recordingPreferences)
        }

        /// Removes the folder and the suite.
        func tearDown() {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        /// Writes a stand-in take into the folder.
        ///
        /// - Parameter name: The file's name.
        /// - Returns: The file.
        func writeTake(_ name: String) throws -> URL {
            let url = folder.appending(path: name)
            try Data(repeating: 0x41, count: 64).write(to: url)
            return url
        }

        /// Sends a `recording.*` event naming a file on the model's bus and
        /// hands the delivered event to the model's recording handler, as
        /// its bus observer does once the engine runs.
        ///
        /// - Parameters:
        ///   - name: The event's name.
        ///   - file: The file its `path` names.
        func deliver(_ name: String, file: URL) async throws {
            let stream = model.eventBus.events()
            model.eventBus.event(name, domain: .output, params: ["path": .string(file.path(percentEncoded: false))])
            var delivered: EventBusEvent?
            for await event in stream where event.name == name {
                delivered = event
                break
            }
            model.handleRecordingEvent(try #require(delivered))
        }

        /// Every event the model's bus carried while the body ran.
        func events(during body: () async -> Void) async -> [EventBusEvent] {
            let stream = model.eventBus.events()
            await body()
            model.eventBus.shutdown()
            var events: [EventBusEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
    }

    @Test("A take starting marks its file as being recorded and has the Library re-read")
    func takeStartingMarksTheFile() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let take = try fixture.writeTake("Tingra 2026-09-12 10.00.00.mov")
        _ = try fixture.writeTake("Tingra 2026-09-12 09.00.00.mov")

        try await fixture.deliver("recording.started", file: take)

        let marked = try #require(fixture.model.fileBeingRecorded)
        #expect(FolderListing.isSameFile(marked, take))
        #expect(fixture.model.isBeingRecorded(take))
        #expect(fixture.model.recordingRevision == 1)
        let rows = LibraryItem.recordings(in: fixture.folder, recording: fixture.model.fileBeingRecorded)
        #expect(rows.map(\.isRecording) == [true, false])
        #expect(rows.first?.name == take.lastPathComponent)
    }

    @Test("A take finalized clears the mark and has the Library re-read again")
    func takeFinalizedClearsTheMark() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let take = try fixture.writeTake("Tingra 2026-09-12 10.00.00.mov")

        try await fixture.deliver("recording.started", file: take)
        try await fixture.deliver("recording.stopped", file: take)

        #expect(fixture.model.fileBeingRecorded == nil)
        #expect(!fixture.model.isBeingRecorded(take))
        #expect(fixture.model.recordingRevision == 2)
        let rows = LibraryItem.recordings(in: fixture.folder, recording: fixture.model.fileBeingRecorded)
        #expect(rows.allSatisfy { !$0.isRecording })
    }

    @Test("Move to Trash refuses the take being written, keeps the file, and reports only its name")
    func trashRefusesTheTakeBeingWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let take = try fixture.writeTake("Tingra 2026-09-12 10.00.00.mov")
        try await fixture.deliver("recording.started", file: take)

        var reason: String?
        let events = await fixture.events { reason = await fixture.model.trashRecording(at: take) }

        let refusal = try #require(reason)
        #expect(refusal.contains(take.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: take.path(percentEncoded: false)))
        #expect(fixture.model.recordingRevision == 1)
        let error = try #require(events.first { $0.name == "recording.trash" })
        #expect(error.group == .error)
        #expect(error.domain == .output)
        #expect(error.params?["file"] == .string(take.lastPathComponent))
        #expect(error.params?["reason"] == .string("recording"))
        for value in error.params?.values ?? [:].values {
            if case .string(let text) = value { #expect(!text.contains("/"), "a param carries a path: \(text)") }
        }
        #expect(!events.contains { $0.name == "recording.trashed" })
    }

    @Test("Another take in the folder is not the one being written")
    func otherTakeIsNotBeingRecorded() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let rolling = try fixture.writeTake("Tingra 2026-09-12 10.00.00.mov")
        let earlier = try fixture.writeTake("Tingra 2026-09-12 09.00.00.mov")

        try await fixture.deliver("recording.started", file: rolling)

        #expect(fixture.model.isBeingRecorded(rolling))
        #expect(!fixture.model.isBeingRecorded(earlier))
    }

    @Test("Choosing a recordings folder persists it and has the Library re-read")
    func folderChoicePersists() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let chosen = fixture.folder.appending(path: "Shows", directoryHint: .isDirectory)

        fixture.model.setRecordingFolder(chosen)

        #expect(fixture.model.recordingFolder == chosen)
        #expect(fixture.model.recordingRevision == 1)
        let defaults = try #require(UserDefaults(suiteName: fixture.suiteName))
        #expect(
            RecordingPreferences(defaults: defaults).folder.path(percentEncoded: false)
                == chosen.path(percentEncoded: false))
    }
}
