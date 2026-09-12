//
//  SnapshotModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import Foundation
import ImageIO
import Testing
import TingraAudio
import TingraEventBus
import TingraPlugInKit

@testable import TingraApp

/// An audio monitor that plays nothing, so a model under test never opens
/// an output device.
private struct SilentMonitor: AudioMonitor {
    func availableDevices() async -> [AudioMonitorDevice] { [] }
    func deviceUpdates() async -> AsyncStream<[AudioMonitorDevice]> { AsyncStream { $0.finish() } }
    func start(device: AudioMonitorDevice, format: MixFormat) async throws {}
    func stop() async {}
    func play(_ audio: CapturedAudio) async {}
    func setLevel(_ level: Double) async {}
}

/// The model's ``EngineModel/saveSnapshot(_:)`` over synthetic frames in its
/// relays (ARCHITECTURE.md, "Snapshots"): the engine is never started, and
/// the snapshots folder is a temporary one, never the operator's.
@MainActor
@Suite("EngineModel snapshots")
struct SnapshotModelTests {
    /// A model whose snapshots folder is a fresh temporary one, with the
    /// suite and folder to clean up.
    private struct Fixture {
        /// The model under test.
        let model: EngineModel

        /// The snapshots folder, not yet on disk.
        let folder: URL

        /// The throwaway defaults suite's name.
        let suiteName: String

        /// Creates the fixture.
        init() throws {
            suiteName = "SnapshotModelTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            folder = URL.temporaryDirectory
                .appending(path: "tingra-snapshot-model-\(UUID().uuidString)")
                .appending(path: "Tingra Snapshots", directoryHint: .isDirectory)
            let preferences = SnapshotPreferences(defaults: defaults)
            preferences.folder = folder
            model = EngineModel(monitor: SilentMonitor(), snapshotPreferences: preferences)
        }

        /// Removes the folder and the suite.
        func tearDown() {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        /// The images in the folder.
        var files: [URL] {
            SnapshotListing.files(in: folder).map(\.url)
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

    /// An opaque white 32BGRA frame of the given size, IOSurface-backed like
    /// the pipeline's.
    private static func frame(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let pixelBuffer = try #require(status == kCVReturnSuccess ? buffer : nil)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0xFF, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    @Test("A program snapshot writes the program frame at its size and reports the file by name only")
    func programSnapshotIsWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.model.programRelay.latest = try Self.frame(width: 96, height: 54)

        let events = await fixture.events { await fixture.model.saveSnapshot(.program) }

        let file = try #require(fixture.files.first)
        #expect(fixture.files.count == 1)
        #expect(file.lastPathComponent.hasPrefix("Tingra "))
        #expect(file.pathExtension == "png")
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 96)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 54)
        // A pixel buffer's alpha is all ones, which Core Image cannot know:
        // the rendered bytes decide, and an opaque frame writes no alpha.
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool != true)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect([.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo))

        let saved = try #require(events.first { $0.name == "snapshot.saved" })
        #expect(saved.group == .event)
        #expect(saved.domain == .composition)
        #expect(saved.params?["subject"] == .string("program"))
        #expect(saved.params?["file"] == .string(file.lastPathComponent))
        #expect(saved.params?["width"] == .int(96))
        #expect(saved.params?["height"] == .int(54))
        for value in saved.params?.values ?? [:].values {
            if case .string(let text) = value { #expect(!text.contains("/"), "a param carries a path: \(text)") }
        }
        #expect(fixture.model.snapshotRevision == 1)
        #expect(fixture.model.snapshotFeedback?.subject == .program)
        #expect(fixture.model.snapshotFeedback?.outcome == .saved(fileName: file.lastPathComponent))
    }

    @Test("A preview snapshot writes the preview frame")
    func previewSnapshotIsWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.model.previewRelay.latest = try Self.frame(width: 32, height: 18)

        await fixture.model.saveSnapshot(.preview)

        #expect(fixture.files.count == 1)
        #expect(fixture.model.snapshotFeedback?.subject == .preview)
    }

    @Test(
        "A monitor showing nothing writes nothing, traces, and says so on the monitor",
        arguments: [
            SnapshotSubject.program, .preview, .input(InputID(rawValue: "cam-1")), .layer,
        ])
    func noFrameWritesNothing(subject: SnapshotSubject) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let events = await fixture.events { await fixture.model.saveSnapshot(subject) }

        #expect(fixture.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.path(percentEncoded: false)))
        let trace = try #require(events.first { $0.name == "snapshot.unavailable" })
        #expect(trace.group == .trace)
        #expect(trace.params?["subject"] == .string(subject.kind))
        #expect(!events.contains { $0.name == "snapshot.saved" })
        #expect(fixture.model.snapshotFeedback?.outcome == .noPicture)
        #expect(fixture.model.snapshotRevision == 0)
    }

    @Test("Each subject reads the monitor's own source: the relays for the buses")
    func subjectsMapToTheMonitorsSources() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        #expect((model.snapshotSource(for: .program) as? ProgramFrameRelay) === model.programRelay)
        #expect((model.snapshotSource(for: .preview) as? ProgramFrameRelay) === model.previewRelay)
        #expect(
            (model.snapshotSource(for: .input(InputID(rawValue: "cam-1"))) as? InputFrameSource)?.id.rawValue == "cam-1"
        )
        #expect(model.snapshotSource(for: .layer) is LayerMonitorSource)
    }

    @Test("The file name's subject is the bus's localized name, or an input's name")
    func subjectNames() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        #expect(
            model.snapshotSubjectName(for: .program)
                == String(
                    localized: "Program", comment: "Name of the program bus — labels its monitor and its switcher row"))
        #expect(
            model.snapshotSubjectName(for: .preview)
                == String(
                    localized: "Preview", comment: "Name of the preview bus — labels its monitor and its switcher row"))
        // An input the model has never discovered falls back to its id.
        #expect(model.snapshotSubjectName(for: .input(InputID(rawValue: "cam-1"))) == "cam-1")
    }

    @Test("Choosing a folder persists it and has the Library re-read")
    func folderChoicePersists() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let chosen = fixture.folder.deletingLastPathComponent().appending(path: "Stills", directoryHint: .isDirectory)

        fixture.model.setSnapshotFolder(chosen)

        #expect(fixture.model.snapshotFolder == chosen)
        #expect(fixture.model.snapshotRevision == 1)
        let defaults = try #require(UserDefaults(suiteName: fixture.suiteName))
        #expect(
            SnapshotPreferences(defaults: defaults).folder.path(percentEncoded: false)
                == chosen.path(percentEncoded: false))
    }
}
