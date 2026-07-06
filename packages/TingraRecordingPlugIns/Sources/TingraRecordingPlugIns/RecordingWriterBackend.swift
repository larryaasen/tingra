//
//  RecordingWriterBackend.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The minimal file-writer backend the recording service drives.
///
/// Abstracting the concrete `AVAssetWriter` behind this seam is what makes
/// ``AVAssetWriterRecordingService``'s lifecycle — open, append, finalize,
/// failure — unit-testable with a mock, so tests never touch the disk or the
/// hardware encoder (CLAUDE.md, Testing: prefer mocks; no real file I/O that
/// would make CI flaky). The real `AVAssetWriter` path is exercised end to
/// end by the streaming integration tests (recording a generator to a temp
/// file, verified with `ffprobe`).
///
/// An actor conforms in production (``AVAssetWriterBackend``), so its
/// non-`Sendable` `AVAssetWriter` state stays isolated without any
/// `@unchecked Sendable`; the requirements are `async` to match.
protocol RecordingWriterBackend: Sendable {
    /// Opens the file and prepares the program's tracks (per
    /// ``StreamConfiguration/includesVideo`` /
    /// ``StreamConfiguration/includesAudio``), then begins writing.
    ///
    /// Throws ``RecordingServiceError`` if the file cannot be created or the
    /// writer refuses to start.
    func open(file: RecordingFile, configuration: StreamConfiguration) async throws

    /// Appends one program video frame. Returns `false` only on a terminal
    /// write error; a frame dropped for backpressure (the track is not ready
    /// for more data) returns `true` — a skipped frame is not a failure.
    func appendVideo(_ frame: CapturedFrame) async -> Bool

    /// Appends program audio. Returns `false` only on a terminal write
    /// error; a buffer dropped for backpressure returns `true`.
    func appendAudio(_ buffer: CapturedAudio) async -> Bool

    /// Finishes the tracks, flushes, and finalizes the file so it is
    /// playable. Safe to call even if the writer already failed.
    func finish() async

    /// A developer-facing description of the writer's terminal failure, or
    /// nil if the writer is healthy — read after an append returns `false`
    /// or after ``finish()`` to surface a finalize error.
    func failureReason() async -> String?
}
