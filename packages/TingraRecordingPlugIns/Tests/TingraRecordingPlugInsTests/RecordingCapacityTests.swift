//
//  RecordingCapacityTests.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraRecordingPlugIns

/// The pre-flight free-space check: the capacity arithmetic, and the refusal
/// it drives in the recording service (ARCHITECTURE.md, "Recording in the
/// app").
@Suite("RecordingCapacity")
struct RecordingCapacityTests {
    /// The file every test would open (never actually written).
    private static func makeFile() -> RecordingFile {
        RecordingFile(url: URL(filePath: "/tmp/tingra-capacity-test.mov"), container: .mov)
    }

    /// Bytes per second at the default settings: 4,500,000 + 160,000 bits.
    private static let defaultBytesPerSecond = 582_500.0

    @Test("Bytes per second sums only the tracks the program carries")
    func bytesPerSecondSumsEnabledTracks() {
        let both = StreamConfiguration()
        #expect(RecordingCapacity.bytesPerSecond(at: both) == Self.defaultBytesPerSecond)

        let videoOnly = StreamConfiguration(includesVideo: true, includesAudio: false)
        #expect(RecordingCapacity.bytesPerSecond(at: videoOnly) == 4_500_000.0 / 8.0)

        let audioOnly = StreamConfiguration(includesVideo: false, includesAudio: true)
        #expect(RecordingCapacity.bytesPerSecond(at: audioOnly) == 160_000.0 / 8.0)
    }

    @Test("A program carrying no media has no answer, and never refuses on space")
    func noMediaHasNoSize() {
        let empty = StreamConfiguration(includesVideo: false, includesAudio: false)
        #expect(RecordingCapacity.bytesPerSecond(at: empty) == nil)

        let capacity = RecordingCapacity(availableBytes: 0)
        #expect(capacity.recordableSeconds(at: empty) == nil)
        // Nothing to size, so the writer's own validation is what complains.
        #expect(capacity.hasRoom(for: empty))
    }

    @Test("Recordable seconds divide the available bytes by the bitrate")
    func recordableSecondsDivides() throws {
        let capacity = RecordingCapacity(availableBytes: Int64(Self.defaultBytesPerSecond * 600))
        let seconds = try #require(capacity.recordableSeconds(at: StreamConfiguration()))
        #expect(abs(seconds - 600) < 0.001)
    }

    @Test("An empty volume records for no time at all")
    func emptyVolumeRecordsNothing() throws {
        let seconds = try #require(RecordingCapacity(availableBytes: 0).recordableSeconds(at: StreamConfiguration()))
        #expect(seconds == 0)
    }

    @Test("Room is decided at exactly five minutes, inclusive")
    func roomThresholdIsFiveMinutes() {
        let configuration = StreamConfiguration()
        let floor = Self.defaultBytesPerSecond * RecordingCapacity.minimumRecordableSeconds

        #expect(RecordingCapacity(availableBytes: Int64(floor)).hasRoom(for: configuration))
        #expect(RecordingCapacity(availableBytes: Int64(floor) + 1).hasRoom(for: configuration))
        #expect(RecordingCapacity(availableBytes: Int64(floor) - 1).hasRoom(for: configuration) == false)
    }

    @Test("The minimum recordable stretch is five minutes")
    func minimumIsFiveMinutes() {
        #expect(RecordingCapacity.minimumRecordableSeconds == 300)
    }

    @Test("Starting on a volume without room throws before the writer is opened")
    func tooLittleSpaceRefusesStart() async throws {
        let backend = MockRecordingWriter()
        let service = AVAssetWriterRecordingService(
            configuration: StreamConfiguration(),
            backend: backend,
            capacityProbe: probe(reporting: 10_000_000)
        )

        await #expect(throws: RecordingServiceError.self) {
            try await service.start(to: Self.makeFile())
        }
        // Refused before the writer was touched: nothing was opened, so
        // nothing needs finalizing.
        #expect(await backend.opened == nil)
    }

    @Test("The refusal is an identified recording error naming the space and the shortfall")
    func refusalIsIdentifiedAndDescriptive() async throws {
        let service = AVAssetWriterRecordingService(
            configuration: StreamConfiguration(),
            backend: MockRecordingWriter(),
            capacityProbe: probe(reporting: 10_000_000)
        )

        do {
            try await service.start(to: Self.makeFile())
            Issue.record("A volume with 10 MB free should refuse a recording")
        } catch let error as RecordingServiceError {
            #expect(error.identifier == .recordingFailed)
            let message = error.description
            #expect(message.contains("/tmp/tingra-capacity-test.mov"))
            #expect(message.contains("10"))
            #expect(message.localizedStandardContains("minute"))
        }
    }

    @Test("Starting on a volume with room opens the writer")
    func enoughSpaceOpensWriter() async throws {
        let backend = MockRecordingWriter()
        let service = AVAssetWriterRecordingService(
            configuration: StreamConfiguration(),
            backend: backend,
            capacityProbe: probe(reporting: Int64(Self.defaultBytesPerSecond * 3600))
        )

        try await service.start(to: Self.makeFile())
        #expect(await backend.opened != nil)
    }

    @Test("A volume that cannot be measured does not refuse")
    func unmeasurableVolumeDoesNotRefuse() async throws {
        let backend = MockRecordingWriter()
        let service = AVAssetWriterRecordingService(
            configuration: StreamConfiguration(),
            backend: backend,
            capacityProbe: { _ in nil }
        )

        try await service.start(to: Self.makeFile())
        #expect(await backend.opened != nil)
    }

    @Test("Measuring a real folder reports a positive reading")
    func measuringARealFolderReads() throws {
        // The temporary directory always exists on a running Mac; this is the
        // one test that touches the file system, and it only reads.
        let capacity = try #require(RecordingCapacity.measure(at: URL.temporaryDirectory))
        #expect(capacity.availableBytes > 0)
    }

    @Test("Measuring a file that does not exist yet measures its folder")
    func measuringAMissingFileUsesItsFolder() throws {
        let file = URL.temporaryDirectory.appending(path: "tingra-not-created-\(UUID().uuidString).mov")
        let capacity = try #require(RecordingCapacity.measure(at: file))
        #expect(capacity.availableBytes > 0)
    }

    @Test("Two readings of the same free space are equal")
    func equality() {
        #expect(RecordingCapacity(availableBytes: 42) == RecordingCapacity(availableBytes: 42))
        #expect(RecordingCapacity(availableBytes: 42) != RecordingCapacity(availableBytes: 43))
    }
}
