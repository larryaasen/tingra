//
//  AVAssetWriterRecordingServiceTests.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraRecordingPlugIns

/// Lifecycle tests for the recording service over a mock backend: start,
/// append, finalize, and the failure paths — no disk, no encoder (the real
/// `AVAssetWriter` path is covered by the streaming integration tests).
@Suite("AVAssetWriterRecordingService")
struct AVAssetWriterRecordingServiceTests {
    /// The file every test opens (never actually written by the mock).
    private static func makeFile() -> RecordingFile {
        RecordingFile(url: URL(filePath: "/tmp/tingra-test.mov"), container: .mov)
    }

    @Test("Start opens the backend and appends flow through to it")
    func startOpensAndAppends() async throws {
        let backend = MockRecordingWriter()
        let service = AVAssetWriterRecordingService(configuration: StreamConfiguration(), backend: backend)

        try await service.start(to: Self.makeFile())
        let opened = await backend.opened
        #expect(opened?.file.container == .mov)

        await service.send(video: try #require(makeFrame(pts: CMTime(value: 1, timescale: 30))))
        await service.send(audio: try #require(makeAudio(pts: CMTime(value: 1, timescale: 48_000))))
        #expect(await backend.videoPTS == [CMTime(value: 1, timescale: 30)])
        #expect(await backend.audioPTS == [CMTime(value: 1, timescale: 48_000)])
    }

    @Test("Media sent before start is ignored")
    func mediaBeforeStartIgnored() async throws {
        let backend = MockRecordingWriter()
        let service = AVAssetWriterRecordingService(configuration: StreamConfiguration(), backend: backend)
        await service.send(video: try #require(makeFrame(pts: .zero)))
        #expect(await backend.videoPTS.isEmpty)
    }

    @Test("A setup failure throws from start and is an identified recording error")
    func startFailureThrows() async {
        let backend = MockRecordingWriter(openError: .unwritableDestination("no such directory"))
        let service = AVAssetWriterRecordingService(configuration: StreamConfiguration(), backend: backend)
        await #expect(throws: RecordingServiceError.unwritableDestination("no such directory")) {
            try await service.start(to: Self.makeFile())
        }
        #expect(RecordingServiceError.unwritableDestination("x").identifier == .recordingFailed)
    }

    @Test("Stop finalizes the file and finishes the events stream")
    func stopFinalizes() async throws {
        let backend = MockRecordingWriter()
        let service = AVAssetWriterRecordingService(configuration: StreamConfiguration(), backend: backend)
        try await service.start(to: Self.makeFile())

        let collector = Task { await Self.collect(service.events) }
        await service.stop()
        #expect(await backend.finishCount == 1)
        // A clean stop yields no failure event and finishes the stream.
        #expect(await collector.value == [])
    }

    @Test("Stop is safe to call more than once and finalizes only once")
    func stopIsIdempotent() async throws {
        let backend = MockRecordingWriter()
        let service = AVAssetWriterRecordingService(configuration: StreamConfiguration(), backend: backend)
        try await service.start(to: Self.makeFile())
        await service.stop()
        await service.stop()
        #expect(await backend.finishCount == 1)
    }

    @Test("A write error reports failed once, and further media is dropped")
    func writeErrorReportsOnce() async throws {
        // Fail on the second append (the first audio buffer after one video).
        let backend = MockRecordingWriter(failAtAppend: 2)
        let service = AVAssetWriterRecordingService(configuration: StreamConfiguration(), backend: backend)
        try await service.start(to: Self.makeFile())
        let collector = Task { await Self.collect(service.events) }

        await service.send(video: try #require(makeFrame(pts: CMTime(value: 1, timescale: 30))))
        await service.send(audio: try #require(makeAudio(pts: CMTime(value: 1, timescale: 48_000))))
        // Both further sends are dropped: the recording has failed.
        await service.send(video: try #require(makeFrame(pts: CMTime(value: 2, timescale: 30))))
        await service.send(audio: try #require(makeAudio(pts: CMTime(value: 2, timescale: 48_000))))
        await service.stop()

        let events = await collector.value
        #expect(events == [.failed(reason: "scripted write error at append 2")])
        // Only the first video frame landed; nothing after the failure.
        #expect(await backend.videoPTS == [CMTime(value: 1, timescale: 30)])
        #expect(await backend.audioPTS.isEmpty)
    }

    @Test("A finalize failure surfaced only at stop reports failed once")
    func finalizeFailureReported() async throws {
        let backend = MockRecordingWriter(finishFailureReason: "disk full on finalize")
        let service = AVAssetWriterRecordingService(configuration: StreamConfiguration(), backend: backend)
        try await service.start(to: Self.makeFile())
        let collector = Task { await Self.collect(service.events) }
        await service.stop()
        #expect(await collector.value == [.failed(reason: "disk full on finalize")])
    }

    /// Drains a recording event stream to an array (it finishes at stop).
    private static func collect(_ stream: AsyncStream<RecordingServiceEvent>) async -> [RecordingServiceEvent] {
        var events: [RecordingServiceEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }
}
