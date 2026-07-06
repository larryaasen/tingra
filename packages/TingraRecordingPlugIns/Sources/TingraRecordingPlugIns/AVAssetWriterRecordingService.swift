//
//  AVAssetWriterRecordingService.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The `AVAssetWriter`-backed ``RecordingService``: writes the program to a
/// local `.mov`/`.mp4` file, the concrete implementation behind the
/// recording seam (see ARCHITECTURE.md, Compression: local recording via
/// `AVAssetWriter`).
///
/// The service orchestrates the recording lifecycle — start, append,
/// finalize, and terminal-failure reporting — over a
/// ``RecordingWriterBackend``; the real `AVAssetWriter` lives in
/// ``AVAssetWriterBackend`` behind that seam, so this orchestration is
/// unit-testable with a mock backend and no disk. A write error surfaces
/// once as a ``RecordingServiceEvent/failed(reason:)`` on ``events`` (a file
/// has no reconnect); the session reports it and stops recording while the
/// stream, if any, continues.
public actor AVAssetWriterRecordingService: RecordingService {
    /// The program compression settings the recording is written with.
    private let configuration: StreamConfiguration

    /// The file-writer backend (the real `AVAssetWriter` in production, a
    /// mock in tests).
    private let backend: any RecordingWriterBackend

    /// Whether the recording is accepting media — false before start, after
    /// a failure, and after stop.
    private var active = false

    /// Whether ``stop()`` has finalized the file, so a duplicate stop is a
    /// no-op.
    private var finished = false

    /// Whether a failure has already been reported, so it is reported at
    /// most once.
    private var failureReported = false

    /// The events consumers receive (see ``events``).
    private let eventStream: AsyncStream<RecordingServiceEvent>

    /// The continuation failures are reported through.
    private let eventContinuation: AsyncStream<RecordingServiceEvent>.Continuation

    /// The service's recording events; a single consumer is expected (the
    /// session). Finishes when the service stops.
    public nonisolated var events: AsyncStream<RecordingServiceEvent> { eventStream }

    /// Creates a production service writing through an ``AVAssetWriterBackend``.
    ///
    /// - Parameter configuration: The program's compression settings.
    public init(configuration: StreamConfiguration) {
        self.init(configuration: configuration, backend: AVAssetWriterBackend())
    }

    /// Creates a service over a given backend — the seam tests inject a mock
    /// through.
    ///
    /// - Parameters:
    ///   - configuration: The program's compression settings.
    ///   - backend: The file-writer backend to drive.
    init(configuration: StreamConfiguration, backend: any RecordingWriterBackend) {
        self.configuration = configuration
        self.backend = backend
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: RecordingServiceEvent.self)
    }

    /// Opens the file and begins recording. Throws ``RecordingServiceError``
    /// on a setup failure — before any media is appended.
    public func start(to file: RecordingFile) async throws {
        try await backend.open(file: file, configuration: configuration)
        active = true
    }

    /// Appends one program video frame; reports a terminal write error once.
    public func send(video frame: CapturedFrame) async {
        guard active else { return }
        if await backend.appendVideo(frame) == false {
            await reportFailure()
        }
    }

    /// Appends program audio; reports a terminal write error once.
    public func send(audio buffer: CapturedAudio) async {
        guard active else { return }
        if await backend.appendAudio(buffer) == false {
            await reportFailure()
        }
    }

    /// Stops recording: finalizes the file, then reports a finalize failure
    /// if one surfaced and was not already reported. Safe to call more than
    /// once, and finalizes whatever was written even after a mid-recording
    /// failure.
    public func stop() async {
        guard !finished else { return }
        finished = true
        active = false
        await backend.finish()
        if !failureReported, let reason = await backend.failureReason() {
            failureReported = true
            eventContinuation.yield(.failed(reason: reason))
        }
        eventContinuation.finish()
    }

    /// Emits a terminal failure once, then stops accepting media (a file
    /// has no reconnect — the recording is over).
    private func reportFailure() async {
        guard !failureReported else { return }
        failureReported = true
        active = false
        let reason = await backend.failureReason() ?? "the recording writer reported a write error"
        eventContinuation.yield(.failed(reason: reason))
    }
}
