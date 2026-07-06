//
//  StreamSessionRecordingTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraHost

/// Tests the recording sink inside a stream session: it receives the same
/// program media the stream does, is finalized on every teardown path, fails
/// the run on a setup error, and reports a mid-recording failure without
/// ending the stream (CLI.md, "Recording and control").
@Suite("StreamSession recording")
struct StreamSessionRecordingTests {
    /// Collects the events a session emits on the bus.
    private final class Collected: Sendable {
        private let events = Mutex<[EventBusEvent]>([])
        func consume(_ stream: AsyncStream<EventBusEvent>) -> Task<Void, Never> {
            Task { for await event in stream { events.withLock { $0.append(event) } } }
        }
        func named(_ name: String) -> [EventBusEvent] { events.withLock { $0.filter { $0.name == name } } }
    }

    /// The recording file target sessions in this suite write to.
    private static func makeFile() -> RecordingFile {
        RecordingFile(url: URL(filePath: "/tmp/tingra-session-test.mov"), container: .mov)
    }

    /// A destination sessions in this suite stream to.
    private static func makeDestination() throws -> Destination {
        Destination(url: try #require(URL(string: "rtmp://localhost:1935/live")), streamKey: "tingra_test_key")
    }

    /// Builds a session with a recording sink over the given services.
    private static func makeSession(
        service: MockStreamingService,
        recording: MockRecordingService,
        recordingFile: RecordingFile?,
        clock: any EngineClock,
        eventBus: EventBus,
        policy: StreamSession.Policy,
        audioBuffers: [CapturedAudio] = []
    ) throws -> StreamSession {
        StreamSession(
            videoInput: StubInput(id: "camera-1", name: "Stub Camera", kind: .camera),
            audioInput: StubInput(id: "mic-1", name: "Stub Microphone", kind: .microphone, audio: audioBuffers),
            service: service,
            destination: try makeDestination(),
            configuration: StreamConfiguration(),
            policy: policy,
            clock: clock,
            eventBus: eventBus,
            recording: recording,
            recordingFile: recordingFile
        )
    }

    @Test("The recording sink receives the same program audio and is finalized on stop")
    func recordingReceivesMediaAndFinalizes() async throws {
        let clock = ManualClock()
        clock.advance(to: CMTime(value: 10, timescale: 1))
        let eventBus = EventBus()
        let events = Collected()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let recording = MockRecordingService()
        let session = try Self.makeSession(
            service: service,
            recording: recording,
            recordingFile: Self.makeFile(),
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 0),
            audioBuffers: [try #require(makeTestAudio(pts: CMTime(value: 105, timescale: 10)))]
        )
        let runTask = Task { try await session.run() }

        // recording.started precedes stream.started (recording opens first).
        let startedRecording = await eventually { recording.startedFile != nil }
        #expect(startedRecording)
        #expect(await eventually { !events.named("recording.started").isEmpty })

        // The same rebased audio reaches both sinks: 10.5s − T0(10s) = 0.5s.
        let audioArrived = await eventually { !recording.audioTimes.isEmpty }
        #expect(audioArrived)
        #expect(recording.audioTimes.first == CMTime(value: 5, timescale: 10))
        #expect(recording.audioTimes == service.audioTimes)

        await session.stop()
        _ = try await runTask.value
        #expect(recording.stops == 1)
        let stoppedRecording = await eventually { !events.named("recording.stopped").isEmpty }
        #expect(stoppedRecording)
    }

    @Test("The recording is finalized even when the connection is lost")
    func recordingFinalizedOnConnectionLost() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let service = MockStreamingService()
        let recording = MockRecordingService()
        let session = try Self.makeSession(
            service: service,
            recording: recording,
            recordingFile: Self.makeFile(),
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(reconnectAttempts: 0, statsIntervalSeconds: 0)
        )
        let runTask = Task { try await session.run() }
        _ = await eventually { service.starts.count == 1 }
        service.reportConnectionLost(reason: "NetConnection.Connect.Closed")

        let outcome = try await runTask.value
        #expect(outcome == .connectionLost)
        // The recording still finalized despite the lost stream.
        #expect(recording.stops == 1)
    }

    @Test("A recording setup failure throws from run before the stream connects")
    func recordingSetupFailureThrows() async throws {
        let clock = ManualClock()
        let service = MockStreamingService()
        let recording = MockRecordingService(startError: .unwritableDestination("no such directory"))
        let session = try Self.makeSession(
            service: service,
            recording: recording,
            recordingFile: Self.makeFile(),
            clock: clock,
            eventBus: EventBus(),
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
        await #expect(throws: RecordingServiceError.unwritableDestination("no such directory")) {
            _ = try await session.run()
        }
        // Recording opens before the connection, so the stream never started.
        #expect(service.starts.isEmpty)
    }

    @Test("A recording write failure reports recordingFailed without ending the stream")
    func recordingWriteFailureDoesNotEndStream() async throws {
        let clock = ManualClock()
        let eventBus = EventBus()
        let events = Collected()
        let eventsTask = events.consume(eventBus.events())
        defer { eventsTask.cancel() }

        let service = MockStreamingService()
        let recording = MockRecordingService()
        let session = try Self.makeSession(
            service: service,
            recording: recording,
            recordingFile: Self.makeFile(),
            clock: clock,
            eventBus: eventBus,
            policy: StreamSession.Policy(statsIntervalSeconds: 0)
        )
        let runTask = Task { try await session.run() }
        _ = await eventually { service.starts.count == 1 }

        recording.reportFailure(reason: "disk full")
        let reported = await eventually { !events.named("recording.write").isEmpty }
        #expect(reported)
        let error = try #require(events.named("recording.write").first)
        #expect(error.params?["identifier"] == .string(ErrorIdentifier.recordingFailed.rawValue))
        #expect(error.group == .error)

        // The stream is unaffected: it ends only on the explicit stop.
        await session.stop()
        let outcome = try await runTask.value
        #expect(outcome == .stopRequested)
        #expect(recording.stops == 1)
    }
}
