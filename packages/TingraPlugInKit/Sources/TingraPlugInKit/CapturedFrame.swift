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
/// ## Frame ownership rule (draft — under review, see TODO.md)
///
/// `CVPixelBuffer` is not `Sendable`, so this type's `@unchecked Sendable`
/// conformance is sound only under the following ownership rule, which every
/// producer and consumer must observe:
///
/// 1. **Transfer at yield.** The producer (an `Input`) hands the frame off
///    when it yields to its `frames()` stream and never touches the pixel
///    buffer again.
/// 2. **One holder at a time.** Exactly one consumer owns the frame at any
///    moment; the compositor's latest-wins slot releases its previous frame
///    when a newer one replaces it.
/// 3. **Immutable after transfer.** No one writes to the pixel buffer after
///    the yield — downstream stages read, composite, and encode from it only.
///
/// This is the deliberate, documented rule CLAUDE.md requires in place of ad
/// hoc `@unchecked` — the rule itself still needs a permanent home in
/// ARCHITECTURE.md once reviewed.
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
