//
//  InputStreamBuffering.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// How many un-taken items a capture input's streams hold, so a consumer that
/// stalls costs a bounded amount of memory instead of every frame or block
/// captured meanwhile (ARCHITECTURE.md, "Bounded frame streams"). The bound
/// lives in each input because `Input.frames()` and `Input.audio()` take no
/// buffering policy.
enum InputStreamBuffering {
    /// The newest frame only: every frame consumer keeps a latest-wins slot,
    /// so an older frame would be overwritten unseen anyway, and a held
    /// frame keeps a capture buffer out of the device's pool.
    static let frames: AsyncStream<CapturedFrame>.Continuation.BufferingPolicy = .bufferingNewest(1)

    /// The newest 96 audio blocks: at least a second, since an application's
    /// tap delivers the device's I/O buffer (512 samples at 48 kHz by
    /// default) and the microphone's tap 1,024 samples or more. Audio is
    /// continuous, so a consumer that only breathes must lose nothing, but
    /// one a second behind cannot play the rest on time.
    static let audio: AsyncStream<CapturedAudio>.Continuation.BufferingPolicy = .bufferingNewest(96)
}
