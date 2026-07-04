//
//  CapturedFrame.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo

/// One video frame moving through the pipeline: an `IOSurface`-backed pixel
/// buffer plus its presentation time on the master clock.
///
/// ## Frame ownership rule
///
/// `CVPixelBuffer` is not `Sendable`, so this type's `@unchecked Sendable`
/// conformance is sound only under the frame ownership rule in
/// ARCHITECTURE.md ("Frame ownership across the `Input` seam"), which every
/// producer and consumer must observe: **transfer at yield** (the producer
/// never touches the buffer after yielding it), **one holder at a time**,
/// and **immutable after transfer**. This type and ``CapturedAudio`` are the
/// only sanctioned `@unchecked Sendable` in the codebase.
public struct CapturedFrame: @unchecked Sendable {
    /// The frame's pixels: `IOSurface`-backed, in the working format
    /// (32BGRA, SDR, tagged BT.709). An untagged buffer is a defect.
    public let pixelBuffer: CVPixelBuffer

    /// The frame's presentation time on the master clock (see CLOCK.md).
    public let presentationTime: CMTime

    /// Creates a frame, transferring ownership of `pixelBuffer` to the
    /// frame per the ownership rule above.
    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
    }
}
