//
//  ShotRenderer.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import TingraPlugInKit

/// The internal seam between the compositor's tick-paced control flow and
/// the pixel work of rendering a shot's layer tree. The compositor decides
/// *when* to render (the program tick) and *what* is current (the shot and
/// the latest frame per input); a renderer turns that into a program frame.
///
/// A renderer is created and used entirely inside the compositor's tick
/// task and never shared across tasks (mirroring `BarsRenderer` in the
/// generator plug-in), so it is deliberately **not** `Sendable` — the
/// compositor takes a `@Sendable` factory and constructs the renderer once,
/// task-confined. This keeps a `CIContext` (thread-safe but not
/// `Sendable`-annotated) out of any cross-isolation transfer without an
/// `@unchecked Sendable`, which the codebase reserves for the two media
/// wrapper types alone (ARCHITECTURE.md, "Frame ownership across the `Input`
/// seam"). The seam also makes the compositor's pacing, stall, and
/// shot-switch behavior testable with a mock renderer and a synthetic clock,
/// no Metal required.
public protocol ShotRenderer {
    /// Renders one program frame for the given shot at the tick's time.
    ///
    /// - Parameters:
    ///   - shot: The layer tree to render, bottom to top, over its
    ///     background.
    ///   - frames: The latest frame each input has produced, keyed by
    ///     ``InputID``. A layer whose input is absent here has no frame yet
    ///     (or has stalled) and contributes nothing.
    ///   - format: The program geometry to render into.
    ///   - time: The program tick's master clock time, stamped onto the
    ///     returned frame — video sinks receive a clean, monotonic,
    ///     constant-rate PTS sequence regardless of input cadence (CLOCK.md).
    /// - Returns: The composited program frame, or `nil` if a buffer could
    ///   not be produced (a transient pool exhaustion, say); the compositor
    ///   skips that tick rather than crash — a renderer problem must never
    ///   take down the pipeline.
    func render(
        shot: Shot,
        frames: [InputID: CapturedFrame],
        format: ProgramFormat,
        time: CMTime
    ) -> CapturedFrame?
}
