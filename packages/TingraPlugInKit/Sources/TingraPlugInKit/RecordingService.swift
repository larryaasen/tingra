//
//  RecordingService.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The recording seam: writes the program to a local file (see GLOSSARY.md,
/// "Recording", and ARCHITECTURE.md — recording via `AVAssetWriter` is a
/// compression sink parallel to streaming output, fed the same program
/// media).
///
/// A narrower sibling of ``StreamingService`` registered through the same
/// ``OutputRegistering`` seam (see ARCHITECTURE.md, "The output
/// registration seam"): recording shares the append shape — `start`,
/// `send(video:)`, `send(audio:)`, `stop` — but drops what only streaming
/// needs. There is no `Destination` (a file has no stream key), no periodic
/// delivery statistics, and no `connectionLost`/reconnect: a file write
/// either succeeds or hits a terminal I/O error, reported once through
/// ``events``.
///
/// The `AVAssetWriter`-backed implementation lives behind this protocol as a
/// recording plug-in, so no other module imports `AVFoundation` for
/// recording. Callers append uncompressed, GPU-resident program media whose
/// timestamps are already on the shared session timeline
/// (`PTS = hostTime − T0`, see CLOCK.md); the service compresses internally
/// (hardware `AVAssetWriter` encode) and never modifies those timestamps.
public protocol RecordingService: Sendable {
    /// Opens the file and begins recording: creates the writer, adds the
    /// program's video and audio tracks, and starts writing.
    ///
    /// Throws ``RecordingServiceError`` if the file cannot be created or the
    /// writer refuses to start (an unwritable path, a rejected format) —
    /// setup failures surface before any media is appended so the caller
    /// can fail the command rather than record nothing silently.
    func start(to file: RecordingFile) async throws

    /// The service's recording events — how a terminal write failure after a
    /// successful start reaches the session (a full disk, a revoked path).
    /// A recording failure is reported, never thrown, because it happens
    /// outside any caller's call; a single consumer is expected (the
    /// session). Finishes when the service stops.
    var events: AsyncStream<RecordingServiceEvent> { get }

    /// Appends one program video frame for compression and writing. The
    /// frame's presentation time is already on the shared session timeline.
    /// Dropped silently once the recording has failed or stopped.
    func send(video frame: CapturedFrame) async

    /// Appends program audio for compression and writing. The buffer's
    /// presentation time is already on the shared session timeline. Dropped
    /// silently once the recording has failed or stopped.
    func send(audio buffer: CapturedAudio) async

    /// Stops recording: finishes the tracks, flushes, and finalizes the
    /// file so it is playable. Safe to call more than once, and called on
    /// every session teardown — a clean stop, a duration elapse, or a
    /// stream that dropped — so the file is always finalized.
    func stop() async
}
