//
//  InputStreamBuffering.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// How many un-taken items a generator's streams hold, so a consumer that
/// stalls costs a bounded amount of memory instead of every frame or buffer
/// produced meanwhile (ARCHITECTURE.md, "Bounded frame streams"). The bound
/// lives in each input because `Input.frames()` and `Input.audio()` take no
/// buffering policy.
enum InputStreamBuffering {
    /// The newest frame only: every frame consumer keeps a latest-wins slot,
    /// so an older frame would be overwritten unseen anyway.
    static let frames: AsyncStream<CapturedFrame>.Continuation.BufferingPolicy = .bufferingNewest(1)

    /// The newest second of audio: 48 buffers of the tone's 1,024 samples at
    /// 48 kHz. Audio is continuous, so a consumer that only breathes must
    /// lose nothing, but one a second behind cannot play the rest on time.
    static let audio: AsyncStream<CapturedAudio>.Continuation.BufferingPolicy = .bufferingNewest(48)
}
