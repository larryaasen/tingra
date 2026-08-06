//
//  AVAssetWriterRecordingService.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
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

    /// How the volume's free space is measured for the pre-flight check
    /// (the real volume in production, a scripted value in tests).
    private let capacityProbe: RecordingCapacityProbe

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
    ///   - capacityProbe: How to measure the target volume's free space;
    ///     the real volume by default.
    init(
        configuration: StreamConfiguration,
        backend: any RecordingWriterBackend,
        capacityProbe: @escaping RecordingCapacityProbe = RecordingCapacity.measure(at:)
    ) {
        self.configuration = configuration
        self.backend = backend
        self.capacityProbe = capacityProbe
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: RecordingServiceEvent.self)
    }

    /// Opens the file and begins recording. Throws ``RecordingServiceError``
    /// on a setup failure — before any media is appended.
    ///
    /// The free space is checked **before** the writer is opened: a volume
    /// that cannot hold ``RecordingCapacity/minimumRecordableSeconds`` at
    /// these settings is refused now rather than reported as a write failure
    /// partway through the show (ARCHITECTURE.md, "Recording in the app").
    public func start(to file: RecordingFile) async throws {
        try checkCapacity(for: file)
        try await backend.open(file: file, configuration: configuration)
        active = true
    }

    /// Refuses a recording the target volume cannot hold.
    ///
    /// A volume that cannot be measured does **not** refuse: an unmeasurable
    /// volume is the writer's problem to report rather than this check's
    /// problem to guess at.
    ///
    /// - Parameter file: Where the recording would be written.
    /// - Throws: ``RecordingServiceError/unwritableDestination(_:)`` naming
    ///   the space available and how long it would record. The existing case
    ///   is reused deliberately — a volume with no room *is* an unwritable
    ///   destination, and adding a case to a public enum in the plug-in
    ///   protocol package would break exhaustive switches in third-party
    ///   code (ARCHITECTURE.md, "Plug-in API stability and versioning").
    private func checkCapacity(for file: RecordingFile) throws {
        guard let capacity = capacityProbe(file.url), !capacity.hasRoom(for: configuration) else { return }
        let available = capacity.availableBytes.formatted(.byteCount(style: .file))
        let minimum = Duration.seconds(RecordingCapacity.minimumRecordableSeconds)
            .formatted(.units(allowed: [.minutes], width: .wide))
        guard let seconds = capacity.recordableSeconds(at: configuration) else { return }
        let recordable = Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        throw RecordingServiceError.unwritableDestination(
            """
            There is not enough free space to record to \(file.url.path): \(available) available holds about \
            \(recordable) at these settings, and a recording needs room for at least \(minimum). Free up space \
            or choose a volume with more room.
            """
        )
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
