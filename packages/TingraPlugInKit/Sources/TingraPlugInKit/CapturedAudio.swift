//
//  CapturedAudio.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia

/// One audio buffer moving through the pipeline: a sample buffer whose
/// presentation time is already on the master clock.
///
/// Audio PTS is the actual host time of capture taken from
/// `AVAudioTime.hostTime` — never a synthetic sample-count position (see
/// CLOCK.md, Timestamp rules). Generators stamp synthesized buffers with
/// master clock time at generation.
///
/// ## Frame ownership rule
///
/// `CMSampleBuffer` is not `Sendable`, so this type's `@unchecked Sendable`
/// conformance is sound only under the frame ownership rule in
/// ARCHITECTURE.md ("Frame ownership across the `Input` seam"), which every
/// producer and consumer must observe: **transfer at yield** (the producer
/// never touches the buffer after yielding it), **one holder at a time**,
/// and **immutable after transfer**. This type and ``CapturedFrame`` are the
/// only sanctioned `@unchecked Sendable` in the codebase.
public struct CapturedAudio: @unchecked Sendable {
    /// The audio samples with their format description, PTS already
    /// normalized onto the master clock.
    public let sampleBuffer: CMSampleBuffer

    /// The buffer's presentation time on the master clock (see CLOCK.md).
    public var presentationTime: CMTime {
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    /// Creates an audio buffer, transferring ownership of `sampleBuffer` to
    /// it per the ownership rule above.
    public init(sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }

    /// A copy of this buffer with its presentation time moved onto a
    /// session timeline: `PTS = hostTime − T0` (see CLOCK.md, Timestamp
    /// rules — the form every sink consumes). The sample data is shared,
    /// not copied; only the timing changes, so the ownership rule carries
    /// over to the returned buffer. Returns nil if Core Media cannot
    /// create the retimed copy.
    ///
    /// - Parameter t0: The session start on the master clock, shared by
    ///   every sink.
    public func rebased(by t0: CMTime) -> CapturedAudio? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMTimeSubtract(presentationTime, t0),
            decodeTimeStamp: .invalid
        )
        var copyOut: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copyOut
        )
        guard status == noErr, let copy = copyOut else { return nil }
        return CapturedAudio(sampleBuffer: copy)
    }
}
