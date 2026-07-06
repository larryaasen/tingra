//
//  MockRecordingWriter.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import TingraPlugInKit

@testable import TingraRecordingPlugIns

/// A scripted ``RecordingWriterBackend`` for lifecycle tests: records every
/// call and lets a test inject an open failure, a write failure at a chosen
/// append, or a finalize failure — no disk, no hardware encoder.
actor MockRecordingWriter: RecordingWriterBackend {
    /// The recorded state a test inspects.
    private(set) var opened: (file: RecordingFile, configuration: StreamConfiguration)?
    /// The PTS of every video frame appended (after any that were dropped).
    private(set) var videoPTS: [CMTime] = []
    /// The PTS of every audio buffer appended.
    private(set) var audioPTS: [CMTime] = []
    /// How many times ``finish()`` was called.
    private(set) var finishCount = 0

    /// An error ``open(file:configuration:)`` throws once, if set.
    private let openError: RecordingServiceError?
    /// The append index (1-based, counting video and audio together) at which
    /// a terminal write error is returned; nil never fails.
    private let failAtAppend: Int?
    /// A finalize failure surfaced only through ``failureReason()`` after
    /// ``finish()``.
    private let finishFailureReason: String?

    /// The running count of append calls, to trigger ``failAtAppend``.
    private var appendCount = 0
    /// The terminal failure reason once a write error has been returned.
    private var writeFailureReason: String?

    /// Creates a mock with optional scripted failures.
    init(
        openError: RecordingServiceError? = nil,
        failAtAppend: Int? = nil,
        finishFailureReason: String? = nil
    ) {
        self.openError = openError
        self.failAtAppend = failAtAppend
        self.finishFailureReason = finishFailureReason
    }

    func open(file: RecordingFile, configuration: StreamConfiguration) throws {
        if let openError { throw openError }
        opened = (file, configuration)
    }

    func appendVideo(_ frame: CapturedFrame) -> Bool {
        recordAppend { videoPTS.append(frame.presentationTime) }
    }

    func appendAudio(_ buffer: CapturedAudio) -> Bool {
        recordAppend { audioPTS.append(CMSampleBufferGetPresentationTimeStamp(buffer.sampleBuffer)) }
    }

    func finish() {
        finishCount += 1
        if let finishFailureReason, writeFailureReason == nil {
            writeFailureReason = finishFailureReason
        }
    }

    func failureReason() -> String? { writeFailureReason }

    /// Counts one append, returning false (a terminal write error) at the
    /// scripted index and recording the sample otherwise.
    private func recordAppend(_ record: () -> Void) -> Bool {
        appendCount += 1
        if let failAtAppend, appendCount == failAtAppend {
            writeFailureReason = "scripted write error at append \(appendCount)"
            return false
        }
        record()
        return true
    }
}
