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
}
