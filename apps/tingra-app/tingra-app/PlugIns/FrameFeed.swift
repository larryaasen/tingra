//
//  FrameFeed.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import IOSurface
import TingraAppPlugInKit
import TingraPlugInKit

/// One numbered state of a bus as a plug-in is sent it: the frame's
/// surface, or an empty bus.
nonisolated struct PlugInFrameUpdate: Sendable {
    /// The change's number; passed back to wait for the next.
    let sequence: UInt64

    /// Whether the bus has nothing on it.
    let isEmpty: Bool

    /// The frame's surface. Nil for an empty bus — and for a frame whose
    /// pixel buffer has no `IOSurface` behind it, which the working format
    /// forbids (ARCHITECTURE.md, "Color and pixel format conventions") and
    /// the handler reports rather than sends.
    let surface: IOSurface?

    /// The frame's time on the master clock, in seconds; `0` when empty.
    let time: Double
}

/// Where a plug-in's connection gets the frames it asks for (PLUGINS.md,
/// "Frames across the boundary"), behind a seam so the method handler is
/// tested with scripted frames and no compositor.
nonisolated protocol PlugInFrameFeeding: Sendable {
    /// A bus's state once it has changed past `sequence` — now, or as soon
    /// as it does.
    ///
    /// - Parameters:
    ///   - bus: The bus.
    ///   - sequence: The last change the caller was sent; `0` for none.
    /// - Returns: The update, or nil when the calling task was cancelled.
    func next(of bus: FrameBus, after sequence: UInt64) async -> PlugInFrameUpdate?
}

/// The app's two monitor relays as plug-ins follow them: the very frames
/// the program and preview monitors draw, surfaced as the `IOSurface`
/// behind each pixel buffer — no copy, and no second tap on the compositor.
nonisolated struct RelayFrameFeed: PlugInFrameFeeding {
    /// The program monitor's relay.
    let program: ProgramFrameRelay

    /// The preview monitor's relay.
    let preview: ProgramFrameRelay

    func next(of bus: FrameBus, after sequence: UInt64) async -> PlugInFrameUpdate? {
        let relay =
            switch bus {
            case .program: program
            case .preview: preview
            }
        guard let update = await relay.next(after: sequence) else { return nil }
        guard let frame = update.frame else {
            return PlugInFrameUpdate(sequence: update.sequence, isEmpty: true, surface: nil, time: 0)
        }
        let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue()
        let seconds = frame.presentationTime.seconds
        return PlugInFrameUpdate(
            sequence: update.sequence, isEmpty: false, surface: surface.map { $0 as IOSurface },
            time: seconds.isFinite ? seconds : 0)
    }
}
